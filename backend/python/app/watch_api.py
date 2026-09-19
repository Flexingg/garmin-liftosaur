"""Watch-facing API: serve the plan, and write finished workouts back to Liftosaur.

The watch is a thin client: it holds no Liftosaur credentials. It fetches the
compiled plan at the start of a workout and POSTs the sets it logged. This
module is the only place that talks to Liftosaur on the watch's behalf.

Endpoints (mounted under /api/v1):
    GET  /watch/plan            compiled plan (app.plan.get_plan) + cache metadata
    POST /watch/workout         logged sets -> Liftosaur history record (end of workout)
    POST /watch/workout/live    create-then-update one record, per completed set
    POST /watch/workout/discard delete a live record the watch threw away

--- The "show a live workout in the phone app" investigation, and why there
    is no /watch/workout/active endpoint here anymore (2026-09-19) ---

Liftosaur's own type (src/types.ts:977 in the upstream repo) treats a history
record with NO endTime as "in progress". But the only write surface this
backend has is the MCP tools create_history_record/update_history_record
(lambda/mcp/tools.ts:189-214 upstream), which accept nothing but a Liftohistory
`text` string, and that text is turned into a record by
LiftohistoryDeserializer_deserialize (src/liftohistory/liftohistoryDeserializer.ts),
called directly from ApiV1_createHistory/ApiV1_updateHistory
(lambda/utils/apiv1.ts:161,243). That deserializer *unconditionally* computes
`endTime = startTime + (durationSec ?? 0) * 1000` (liftohistoryDeserializer.ts:213-214)
- there is no metadata key, no tool argument, and no code path that leaves it
undefined.

The real "in progress" signal upstream is a completely different piece of
state: `storage.progress` (src/types.ts:967 `vtype`, :977 `endTime?`, :1877
`_VStorage.progress`), read by the app via `state.storage.progress?.[0]`
(src/models/progress.ts:839,852) and by the iOS engine's
`getProgress(storageJson:)` (ios/LiftosaurWatch/Engine/WorkoutManager.swift:250-254).
It IS synced, but only via `POST /api/sync2` (lambda/index.ts:552), which
authenticates with a **session cookie** (`getCurrentUserIdFromCookie`,
lambda/index.ts:279) and merges a diff into the stored blob field-by-field
using per-field version tracking (`CONTROLLED_FIELDS.progress`,
src/types.ts:1985-2001; `userDao.applySafeSync2`, lambda/dao/userDao.ts:241-291).
None of the 41 MCP tools this backend can call touch `storage.progress` at
all, and this backend only ever holds a Liftosaur **API key**
(`plan.api_key()`), never the user's session cookie - a materially different,
heavier credential this project has deliberately never asked for.

**Verdict: NO, not viable through this backend's access.** Getting a workout
to show as "in progress" in the phone app would require `/api/sync2` with the
user's actual logged-in session, not the API-key/MCP surface this backend is
built on - a different trust boundary, out of scope. "No endTime" via the
MCP write surface is not achievable either way (see the deserializer note
above) - not a bug to fix here, a hard boundary of the tool contract.

**What this backend does instead, and what it dropped:**
  1. `duration:` in the text is always the watch's real elapsed time as of
     the moment it posts (Workout.mc's `elapsedMs()`), not a final fixed
     value, so endTime keeps creeping forward with every live update instead
     of jumping straight to a "finished" timestamp. This, and the per-set
     live sync itself (create on the first set, update on every later one),
     is kept - it is genuinely useful on its own merits (a watch crash or
     dead battery mid-session no longer loses the workout), independent of
     whether the phone can show it as "in progress".
  2. A record still being synced live carries a LIVE_NOTE marker as its
     Liftosaur *notes* (visible to the user in the app - legitimately useful:
     "still going"). `to_liftohistory(..., live=True)` writes it,
     `watch_workout_live(..., finished=1)` (the real finish path - see
     Comms.mc postWorkout(), which POSTs to this same /live endpoint) leaves
     it out. Kept for the same reason as (1): still useful on its own, even
     though nothing reads it as a machine-readable signal anymore.
  3. DROPPED: `/watch/workout/active` and the attach-on-launch feature it
     powered (finding a LIVE_NOTE-marked record on watch startup and adopting
     its id/sets instead of starting a second one). Real-device testing
     confirmed it does not work as a substitute for the real thing - a
     workout open in the phone app is not discoverable through the history
     API at all, so there was never anything for a watch-side attach to find
     for the goal this was built for. Removed rather than left running: the
     watch-side code (`Workout.mc`'s `_activeAttach`/`_applyActiveAttach`,
     `Comms.mc`'s `fetchActiveWorkout()`) and this module's
     `parse_liftohistory_record()` reverse parser are gone, not just
     disabled, so neither can be mistaken for a working feature later.
"""
from __future__ import annotations

import datetime as _dt
import json
import urllib.parse

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app import plan as plan_mod

router = APIRouter()

# Notes marker for a record still being live-synced (see module docstring).
# Plain user-visible text by design: while a workout is going, the user
# looking at the Liftosaur app sees why the record is still short/unfinished.
LIVE_NOTE = "Synced live from Garmin watch — workout in progress."


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
    started_at: int | None = Field(
        default=None,
        description="unix seconds; the watch's wall-clock session start, from "
                    "the compact payload's optional 5th header field")
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


def to_liftohistory(w: WorkoutIn, plan: dict | None = None,
                    stamp: int | None = None, live: bool = False) -> str:
    """Build the Liftohistory text for a workout.

    Pure function (no network) so the exact output is unit-tested: get this
    wrong and Liftosaur rejects the record, losing the user's session.

    `stamp` (unix seconds), when given, overrides `w.finished_at`/now. The live
    sync path (`watch_workout_live`) passes the same stamp on every update for
    one record so the record's date stays fixed at the session start rather
    than creeping forward with each set — without this, every update would
    re-date the record to "now". Falling all the way back to `now()` (no
    `stamp`, no `finished_at`) can still shift a record's date once, if the
    service restarted mid-session and the watch sent no `started_at`.

    `live`, when true, prepends the LIVE_NOTE marker (see module docstring)
    as the record's notes - the closest approximation this API can produce
    of "in progress", since the record's endTime itself can never be omitted.
    """
    when = stamp if stamp is not None else (
        w.finished_at or int(_dt.datetime.now(_dt.timezone.utc).timestamp()))
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

    lines = []
    if live:
        lines.append(f"// {LIVE_NOTE}")
    lines.append(f'{stamp} / program: "{w.program or "Liftosaur"}"'
                f' / dayName: "{w.day}" / week: {w.week} / dayInWeek: {w.day_in_week}'
                f' / duration: {w.duration_s}s / exercises: {{')
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

@router.get("/watch/programs")
def watch_programs() -> dict:
    """The user's programs, for the watch's program picker."""
    try:
        progs = plan_mod.list_programs()
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {"programs": progs}


@router.get("/watch/plan")
def watch_plan(section: str | None = None, program: str = "current") -> dict:
    """The compiled plan. 503 when Liftosaur is unreachable, so the watch knows
    to fall back to its baked-in copy instead of showing an empty plan.

    `section` filters the days (e.g. ?section=Week%201). The watch asks for one
    section because the response travels to the phone and then over BLE to the
    watch, so halving ~15KB is worth it.
    """
    try:
        plan = plan_mod.get_plan(program)
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


@router.get("/watch/exercise")
def watch_exercise(name: str) -> dict:
    """Last logged session for one exercise, for the watch's info screen."""
    try:
        return plan_mod.exercise_history(name)
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc




def parse_compact(text: str) -> WorkoutIn:
    """Parse the watch's compact payload into a WorkoutIn.

    The watch sends this rather than JSON because Connect IQ has no JSON encoder
    and makeWebRequest only accepts flat scalars as POST parameters.
    Format: day|section|program|duration_s[|started_at];exercise|weight|reps|amrap;...
    The 5th header field, started_at (unix seconds), is optional: a 4-field
    header (the existing stash on watches that predate live sync) still parses
    exactly as before.
    """
    head, _, rest = text.partition(";")
    fields = head.split("|")
    if len(fields) < 4:
        raise ValueError(f"malformed payload header: {head[:60]!r}")
    sets = []
    for chunk in rest.split(";"):
        if not chunk.strip():
            continue
        f = chunk.split("|")
        if len(f) < 4:
            continue
        sets.append(LoggedSet(exercise=f[0], weight=float(f[1]),
                              reps=int(float(f[2])), amrap=f[3] == "1"))
    started_at = None
    if len(fields) >= 5 and fields[4]:
        try:
            started_at = int(float(fields[4]))
        except ValueError:
            started_at = None
    return WorkoutIn(day=fields[0], section=fields[1], program=fields[2],
                     duration_s=int(float(fields[3])), started_at=started_at,
                     sets=sets)


@router.post("/watch/workout")
async def watch_workout(request: Request, payload: str | None = None,
                        dry_run: int = 0) -> dict:
    """Write a finished workout into Liftosaur as a history record.

    Accepts a JSON body (curl, the build tool, tests) AND the form-encoded
    `payload` field the watch sends - makeWebRequest can only post flat scalars,
    so the watch ships the workout as one compact string.
    """
    ctype = (request.headers.get("content-type") or "").lower()
    if payload:
        # The watch sends the workout in the QUERY STRING with no body at all:
        # the parameters-Dictionary path crashed twice on the device.
        try:
            w = parse_compact(payload)
        except (ValueError, IndexError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    elif "json" in ctype:
        try:
            w = WorkoutIn(**(await request.json()))
        except (ValueError, TypeError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    else:
        # parsed by hand: avoids a python-multipart dependency
        body = (await request.body()).decode(errors="replace")
        payload = (urllib.parse.parse_qs(body).get("payload") or [""])[0]
        if not payload:
            raise HTTPException(status_code=422,
                                detail="no payload field; expected form or JSON")
        try:
            w = parse_compact(payload)
        except (ValueError, IndexError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    if not w.sets:
        raise HTTPException(status_code=422, detail="no sets to record")

    text = to_liftohistory(w, plan=None)
    if dry_run:
        return {"recorded": False, "dry_run": True, "sets": len(w.sets),
                "liftohistory": text}
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


# --------------------------------------------------------------- live sync
#
# Push each completed set to Liftosaur as the workout happens: the record is
# created on the first set and updated after every later one, so the user
# watches it grow in the Liftosaur phone app, and a watch crash or dead
# battery mid-session no longer loses the workout (the end-of-workout post
# above remains the safety net for when the phone was out of range).
#
# In-memory only, keyed by the Liftosaur record id (always a string on the
# wire: it travels as a URL query parameter). Both dicts are best-effort
# bookkeeping, not a durable store - a service restart loses them, which is
# exactly why the payload also carries `started_at` (see to_liftohistory).

_LIVE_STAMPS: dict[str, int] = {}       # record id -> stamp used when created
_LIVE_SET_COUNTS: dict[str, int] = {}   # record id -> highest set count written


class _RecordRejected(Exception):
    """Liftosaur answered a write with content that isn't a successful record
    (the same 200-with-a-rejection-string shape watch_workout() guards against)."""


def _write_result(raw: str) -> dict:
    try:
        obj = json.loads(raw)
    except (TypeError, ValueError):
        raise _RecordRejected(str(raw)[:300]) from None
    if not isinstance(obj, dict) or "id" not in obj:
        raise _RecordRejected(str(raw)[:300])
    return obj


def _live_stamp(record_id: str, started_at: int | None) -> int:
    """Preference order: the payload's started_at (stable across a backend
    restart), then the stamp remembered when this record was created, then
    now() as a last resort."""
    if started_at:
        return started_at
    if record_id and record_id in _LIVE_STAMPS:
        return _LIVE_STAMPS[record_id]
    return int(_dt.datetime.now(_dt.timezone.utc).timestamp())


def _create_live_record(text: str) -> object:
    """create_history_record, validated the same way watch_workout() does.
    Raises HTTPException (502) rather than returning on a rejected write - a
    rejection here must never be reported as a success."""
    try:
        raw = plan_mod.mcp_call("create_history_record", {"text": text})
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    try:
        created = _write_result(raw)
    except _RecordRejected as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Liftosaur did not create the record: {exc}") from exc
    return created["id"]


@router.post("/watch/workout/live")
async def watch_workout_live(payload: str | None = None, record: str = "",
                             dry_run: int = 0, finished: int = 0) -> dict:
    """Create the live record on the first set, update it on every later one.

    `record` is the id the watch already holds ("" the first time). A
    successful write returns the id the watch must remember for the next set.

    `finished=1` is the real finish path (Comms.mc postWorkout() posts here,
    not to /watch/workout - see module docstring): the only difference is the
    LIVE_NOTE marker is left out of the text, which is this API's only way to
    say "done" (endTime itself can't be omitted either way - see module
    docstring for why).
    """
    if not payload:
        raise HTTPException(status_code=422, detail="no payload field")
    try:
        w = parse_compact(payload)
    except (ValueError, IndexError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not w.sets:
        raise HTTPException(status_code=422, detail="no sets to record")

    n = len(w.sets)
    # Never shrink a live record: a late/out-of-order POST carrying fewer sets
    # than the last one already applied for this record must not overwrite it.
    if record and _LIVE_SET_COUNTS.get(record, 0) > n:
        return {"id": record, "skipped": "stale", "sets": n}

    stamp = _live_stamp(record, w.started_at)
    text = to_liftohistory(w, plan=None, stamp=stamp, live=not bool(finished))

    if dry_run:
        return {"recorded": False, "dry_run": True, "id": record or "dry",
                "sets": n, "liftohistory": text}

    if not record:
        new_id = _create_live_record(text)
        rid = str(new_id)
        _LIVE_STAMPS[rid] = stamp
        _LIVE_SET_COUNTS[rid] = n
        return {"id": new_id, "created": True, "sets": n}

    try:
        raw = plan_mod.mcp_call("update_history_record", {"id": record, "text": text})
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    try:
        _write_result(raw)
    except _RecordRejected:
        # The record is gone (deleted or otherwise rejected) - never lose the
        # workout, create a fresh one instead.
        new_id = _create_live_record(text)
        rid = str(new_id)
        _LIVE_STAMPS[rid] = stamp
        _LIVE_SET_COUNTS[rid] = n
        return {"id": new_id, "created": True, "sets": n}

    _LIVE_STAMPS.setdefault(record, stamp)
    _LIVE_SET_COUNTS[record] = n
    return {"id": record, "updated": True, "sets": n}


@router.post("/watch/workout/discard")
async def watch_workout_discard(record: str = "", dry_run: int = 0) -> dict:
    """Delete a live record the watch is throwing away (decision #2: discard
    leaves nothing behind in Liftosaur)."""
    if dry_run:
        return {"deleted": False, "dry_run": True, "id": record}
    if not record:
        # Nothing was ever synced for this workout - a normal case, not an error.
        return {"deleted": False, "reason": "no record"}
    try:
        raw = plan_mod.mcp_call("delete_history_record", {"id": record})
    except plan_mod.LiftosaurError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    _LIVE_STAMPS.pop(record, None)
    _LIVE_SET_COUNTS.pop(record, None)
    # A "not found" reply already satisfies the user's intent - nothing left
    # behind - so it is reported as a success, not a 502.
    if "not found" in raw.lower():
        return {"deleted": True, "id": record, "reason": "already gone"}
    return {"deleted": True, "id": record}
