"""Watch-facing API: serve the plan, and write finished workouts back to Liftosaur.

The watch is a thin client: it holds no Liftosaur credentials. It fetches the
compiled plan at the start of a workout and POSTs the sets it logged. This
module is the only place that talks to Liftosaur on the watch's behalf.

Endpoints (mounted under /api/v1):
    GET  /watch/plan      compiled plan (app.plan.get_plan) + cache metadata
    POST /watch/workout   logged sets -> Liftosaur history record
"""
from __future__ import annotations

import datetime as _dt
import json

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app import plan as plan_mod

router = APIRouter()


class LoggedSet(BaseModel):
    """One completed set as the watch logged it."""
    exercise: str
    weight: float = 0
    reps: int = 0
    amrap: bool = False


class WorkoutIn(BaseModel):
    """A finished watch workout."""
    day: str = Field(..., description="Program day name, e.g. 'Day 1'")
    section: str = ""
    program: str = ""
    week: int = 1
    day_in_week: int = 1
    duration_s: int = 0
    finished_at: int | None = Field(
        default=None, description="unix seconds; defaults to server time")
    sets: list[LoggedSet] = []


# --------------------------------------------------------------- text building

def _fmt_weight(w: float) -> str:
    """Liftohistory wants explicit units; keep whole pounds clean."""
    return f"{int(round(w))}lb"


def _group_sets(sets: list[LoggedSet]) -> list[tuple[str, list[LoggedSet]]]:
    """Group by exercise, preserving the order the user trained them in."""
    order: list[str] = []
    groups: dict[str, list[LoggedSet]] = {}
    for s in sets:
        if s.exercise not in groups:
            groups[s.exercise] = []
            order.append(s.exercise)
        groups[s.exercise].append(s)
    return [(name, groups[name]) for name in order]


def _sets_notation(sets: list[LoggedSet]) -> str:
    """Collapse runs of identical weight/reps/amrap into 'NxR Wlb' notation.

    Liftosaur groups sets, so 5x10 at one weight is '5x10 170lb', while an
    ascending 5/3/1 wave stays as separate entries. An AMRAP set carries '+'.
    """
    parts: list[str] = []
    i = 0
    while i < len(sets):
        cur = sets[i]
        n = 1
        while (i + n < len(sets)
               and sets[i + n].weight == cur.weight
               and sets[i + n].reps == cur.reps
               and sets[i + n].amrap == cur.amrap):
            n += 1
        plus = "+" if cur.amrap else ""
        parts.append(f"{n}x{cur.reps}{plus} {_fmt_weight(cur.weight)}")
        i += n
    return ", ".join(parts)


def _target_notation(ex: dict) -> str:
    """The prescribed sets, so Liftosaur shows what was asked for."""
    parts = []
    for s in ex.get("sets", []):
        plus = "+" if s.get("amrap") else ""
        rest = f" {int(s.get('rest', 0))}s" if s.get("rest") else ""
        parts.append(f"{s.get('reps')}{plus} {int(s.get('weight', 0))}lb{rest}")
    return ", ".join(parts)


def to_liftohistory(w: WorkoutIn, plan: dict | None = None) -> str:
    """Build the Liftohistory text for a finished workout.

    Pure function (no network) so the exact output is unit-tested: get this
    wrong and Liftosaur rejects the record, losing the user's session.
    """
    when = w.finished_at or int(_dt.datetime.now(_dt.timezone.utc).timestamp())
    stamp = _dt.datetime.fromtimestamp(when, _dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")

    # target lookups come from the plan, keyed by exercise display name
    targets: dict[str, dict] = {}
    if plan:
        for d in plan.get("days", []):
            if d.get("name") == w.day:
                for ex in d.get("exercises", []):
                    targets[ex.get("name", "")] = ex
                break

    lines = [f'{stamp} / program: "{w.program or "Liftosaur"}"'
             f' / dayName: "{w.day}" / week: {w.week} / dayInWeek: {w.day_in_week}'
             f' / duration: {w.duration_s}s / exercises: {{']
    for name, sets in _group_sets(w.sets):
        line = f"  {name} / {_sets_notation(sets)}"
        tgt = targets.get(name)
        if tgt:
            t = _target_notation(tgt)
            if t:
                line += f" / target: {t}"
        lines.append(line)
    lines.append("}")
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------- endpoints

@router.get("/watch/plan")
def watch_plan(section: str | None = None) -> dict:
    """The compiled plan. 503 when Liftosaur is unreachable, so the watch knows
    to fall back to its baked-in copy instead of showing an empty plan.

    `section` filters the days (e.g. ?section=Week%201). The watch asks for one
    section because the response travels to the phone and then over BLE to the
    watch, so halving ~15KB is worth it.
    """
    try:
        plan = plan_mod.get_plan()
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if section:
        days = [d for d in plan.get("days", []) if d.get("section") == section]
        if not days:
            raise HTTPException(
                status_code=404,
                detail=f"no days in section '{section}'; "
                       f"have {plan.get('sections', [])}")
        plan = dict(plan, days=days)
    return plan


@router.post("/watch/workout")
def watch_workout(w: WorkoutIn) -> dict:
    """Write a finished workout into Liftosaur as a history record."""
    if not w.sets:
        raise HTTPException(status_code=422, detail="no sets to record")

    text = to_liftohistory(w, plan=None)
    try:
        raw = plan_mod.mcp_call("create_history_record", {"text": text})
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    # Liftosaur reports a REJECTED record as ordinary content, not as an error:
    # a bad program name came back as 'Program "X" not found' with a 200. A real
    # success is a JSON object carrying the new record's id. Treating the
    # rejection as success would tell the user their workout was saved when it
    # had been thrown away.
    try:
        created = json.loads(raw)
    except (TypeError, ValueError):
        raise HTTPException(
            status_code=502,
            detail=f"Liftosaur rejected the workout: {str(raw)[:300]}") from None
    if not isinstance(created, dict) or "id" not in created:
        raise HTTPException(
            status_code=502,
            detail=f"Liftosaur did not create the record: {str(raw)[:300]}")

    return {"recorded": True, "id": created["id"], "sets": len(w.sets),
            "liftohistory": text}
