"""Plan compilation: Liftosaur program -> the watch's concrete workout plan.

This lives in the backend because the backend is the single source of truth for
the plan served to the watch:

    GET  /api/v1/watch/plan     -> this module's get_plan()
    POST /api/v1/watch/workout  -> writes logged sets back into Liftosaur

The embedded build tool (embedded/monkeyc/tools/plan_from_liftosaur.py) does NOT
re-implement this: it fetches this JSON and bakes it into the app as the
offline fallback. One implementation, two consumers.

The Liftosaur API key stays here (server side). The watch never sees it.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request

MCP_URL = "https://www.liftosaur.com/mcp"
CONFIG_FALLBACK = "/home/hermes/.hermes/config.yaml"

# Plan cache: the watch asks at the start of every workout, and the program only
# changes when the user edits it, so don't hit Liftosaur on every request.
_CACHE: dict[str, object] = {}   # program_id -> (at, plan)
CACHE_TTL_S = 600


class LiftosaurError(RuntimeError):
    pass


def api_key() -> str:
    """Key from the environment, else the Hermes config (same key the MCP uses)."""
    key = os.environ.get("LIFTOSAUR_API_KEY", "")
    if key:
        return key
    try:
        with open(CONFIG_FALLBACK) as fh:
            m = re.search(r"lftsk_[A-Za-z0-9]+", fh.read())
            if m:
                return m.group(0)
    except OSError:
        pass
    raise LiftosaurError("no Liftosaur API key (set LIFTOSAUR_API_KEY)")


def mcp_call(name: str, arguments: dict, key: str | None = None,
             timeout: int = 45) -> str:
    """Call one Liftosaur MCP tool and return its text payload."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}}).encode()
    req = urllib.request.Request(
        MCP_URL, data=body, method="POST",
        headers={"Authorization": f"Bearer {key or api_key()}",
                 "Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError) as exc:
        raise LiftosaurError(f"{name} request failed: {exc}") from exc
    if "error" in payload:
        raise LiftosaurError(f"{name} failed: {payload['error']}")
    return payload["result"]["content"][0]["text"]


# --------------------------------------------------------------------- parsing

def parse_weight(lb: str) -> float:
    m = re.search(r"([0-9.]+)\s*lb", lb or "")
    return float(m.group(1)) if m else 0.0


def name_key(name: str) -> str:
    """Normalise an exercise display name for matching rm1 keys.

    "Bench Press" must match the key "benchPress_barbell", and
    "Romanian Deadlift, Barbell" must match "romanianDeadlift_barbell". The
    display name carries spaces and a comma-separated equipment suffix that the
    key does not, so strip both to alphanumerics.
    """
    base = name.split(",")[0]
    return re.sub(r"[^a-z0-9]", "", base.lower())


def lookup_rm1(rm1: dict[str, float], name: str) -> tuple[float, str]:
    """-> (rm1, how). Prefers an exact base-name match: "Bench Press" must not
    match "benchPressCloseGrip", which a naive prefix test would do."""
    nk = name_key(name)
    for k, v in rm1.items():
        if k.split("_")[0] == nk:
            return v, "exact"
    for k, v in rm1.items():
        if k.split("_")[0].startswith(nk):
            return v, "prefix"
    for k, v in rm1.items():
        if nk.startswith(k.split("_")[0]):
            return v, "contained"
    return 0.0, "none"


def round5(x: float) -> int:
    """Gym-plate rounding: nearest 5 lb."""
    return int(round(x / 5.0) * 5.0)


SET_RE = re.compile(
    r"(?P<sets>\d+)\s*x\s*(?P<reps>\d+)(?P<amrap>\+)?"
    r"(?:\s*(?P<weight>\d+(?:\.\d+)?%|\d+(?:\.\d+)?\s*lb))?"
    r"(?:\s*(?P<rest>\d+)\s*s)?")
REST_RE = re.compile(r"(?<![\dx])(\d+)\s*s\b")


def parse_sets(spec: str, default_rest: int) -> list[dict]:
    sets: list[dict] = []
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = SET_RE.match(chunk)
        if not m:
            continue
        reps = int(m.group("reps"))
        amrap = bool(m.group("amrap"))
        weight = m.group("weight") or ""
        rest = int(m.group("rest")) if m.group("rest") else default_rest
        for _ in range(int(m.group("sets"))):
            sets.append({"reps": reps, "amrap": amrap,
                         "weight_expr": weight, "rest": rest})
    return sets


def parse_program(text: str) -> list[dict]:
    """Liftoscript -> [{name, section, exercises:[{name, sets_spec, rest, lb}]}].

    Set blocks are scoped to the WEEK SECTION: "main" is defined under Day 1 and
    reused by Days 2-4 of the same section, while a deload section defines its
    own "main". Treating them as global produced plausible-but-wrong weights
    (40/50/60% instead of 65/75/85%) - see docs/05.
    """
    days: list[dict] = []
    cur: dict | None = None
    section = ""
    sec_blocks: dict[str, dict] = {}
    for raw in text.split("\n"):
        line = raw.strip()
        if line.startswith("//"):
            continue
        head = re.sub(r"\{.*", "", line).strip()
        if not head:
            continue
        if head.startswith("## "):
            cur = {"name": head[3:].strip(), "exercises": [],
                   "section": section, "blocks": sec_blocks}
            days.append(cur)
            continue
        if head.startswith("#"):
            section = head.lstrip("#").strip()
            sec_blocks = {}
            continue
        if head.startswith("!"):
            continue
        parts = [p.strip() for p in head.split("/")]
        name_field = parts[0]
        if len(parts) > 2 and re.match(r"^[A-Za-z][\w ]*$", name_field) and cur is not None:
            rest = 0
            for p in parts[2:]:
                rm = REST_RE.search(p)
                if rm and "x" not in p:
                    rest = int(rm.group(1))
            spec = next((p for p in parts[2:] if re.match(r"^\d+\s*x\s*\d+", p)), "")
            if spec:
                sec_blocks[name_field] = {"sets": parse_sets(spec, rest), "rest": rest}
                continue
        if cur is None:
            continue
        ex_name = name_field.split("[")[0].strip()
        sets_spec = ""
        for p in parts[1:]:
            if p.startswith("...") or re.match(r"^\d+\s*x\s*\d+", p):
                sets_spec = p
                break
        rest = 0
        for p in parts[1:]:
            rm = REST_RE.search(p)
            if rm and not re.match(r"^\d+\s*x", p):
                rest = int(rm.group(1))
        lb = ""
        for p in parts[1:]:
            lm = re.search(r"\d+(?:\.\d+)?\s*lb", p)
            if lm:
                lb = lm.group(0)
                break
        if ex_name and sets_spec:
            cur["exercises"].append({"name": ex_name, "sets_spec": sets_spec,
                                     "rest": rest, "lb": lb})
    return days


def build_plan(days: list[dict], rm1: dict[str, float]) -> tuple[list[dict], list[str]]:
    """-> (plan, warnings). Anything unresolved is reported, never guessed."""
    warnings: list[str] = []
    inline: dict[str, dict] = {}
    for d in days:
        for ex in d["exercises"]:
            if not ex["sets_spec"].startswith("...") and ex["name"] not in inline:
                inline[ex["name"]] = {"sets": parse_sets(ex["sets_spec"], ex["rest"]),
                                      "rest": ex["rest"]}
    out = []
    for d in days:
        exs = []
        for ex in d["exercises"]:
            spec = ex["sets_spec"]
            if spec.startswith("..."):
                ref = spec[3:].strip()
                ref_name = re.sub(r"\[[^\]]*\]", "", ref).strip()
                blk = (d["blocks"].get(ref) or d["blocks"].get(ref_name)
                       or inline.get(ref_name))
                if not blk:
                    warnings.append(f"unresolved block '{spec}' for {ex['name']}")
                    continue
                sets = [dict(s) for s in blk["sets"]]
                rest = ex["rest"] or blk["rest"]
            else:
                sets = parse_sets(spec, ex["rest"])
                rest = ex["rest"]
            if not rest:
                rest = 90
            ex_rm1, how = lookup_rm1(rm1, ex["name"])
            if how == "none":
                pass  # reported below only if the sets actually need a percentage
            for s in sets:
                w = s.pop("weight_expr", "")
                if w.endswith("%"):
                    if ex_rm1:
                        s["weight"] = round5(ex_rm1 * float(w[:-1]) / 100.0)
                    else:
                        s["weight"] = 0
                        warnings.append(f"no rm1 for {ex['name']} ({w})")
                elif w:
                    s["weight"] = round5(parse_weight(w))
                else:
                    s["weight"] = round5(parse_weight(ex["lb"]))
                s["rest"] = s.get("rest") or rest
            exs.append({"name": ex["name"], "rest": rest, "rm1": ex_rm1,
                        "sets": sets})
        if exs:
            out.append({"name": d["name"], "section": d.get("section", ""),
                        "exercises": exs})
    return out, warnings


# ------------------------------------------------------------------- fetching

def _rm1_map() -> dict[str, float]:
    data = json.loads(mcp_call("list_exercise_data", {}))
    out: dict[str, float] = {}
    for e in data.get("exerciseData", []):
        out[str(e["key"]).lower()] = parse_weight(e.get("rm1"))
    return out


def list_programs() -> list[dict]:
    """The user's programs, for the watch's program picker."""
    data = json.loads(mcp_call("list_programs", {}))
    return data.get("programs", [])


def build_from_liftosaur(program_id: str = "current") -> dict:
    prog = json.loads(mcp_call("get_program", {"id": program_id}))
    days = parse_program(prog["text"])
    plan, warnings = build_plan(days, _rm1_map())
    sections = sorted({d["section"] for d in plan if d.get("section")})
    return {
        "program": prog.get("name", ""),
        "program_id": prog.get("id", ""),
        "sections": sections,
        "generated_at": int(time.time()),
        "days": plan,
        "warnings": warnings,
    }


def get_plan(program_id: str = "current", force: bool = False) -> dict:
    """Cached plan for one program. Raises LiftosaurError if Liftosaur is
    unreachable and there is no cached copy, so callers can fall back rather
    than serve a stale lie."""
    now = time.time()
    entry = _CACHE.get(program_id)
    if (not force and isinstance(entry, tuple)
            and (now - float(entry[0])) < CACHE_TTL_S):
        return entry[1]  # type: ignore[return-value]
    plan = build_from_liftosaur(program_id)
    _CACHE[program_id] = (now, plan)
    return plan
