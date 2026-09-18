"""Prove the watch's save path off-device: build the exact compact payload
`WorkoutController.pendingText()` builds, percent-encode it with a Python
mirror of the (fixed) `Comms.urlEncode()`, and POST it to the backend with
`?dry_run=1` so nothing is written into the user's real Liftosaur history.

Why this exists: the device is the only place the Monkey C encoder actually
runs, so this script is how the *algorithm* and the *server* are proven
without a watch in hand. It exists because a broken encoder (commit d084048)
silently turned every `|` and `;` separator into a NUL byte and the backend
rejected every save with HTTP 422 - see docs/06-sync.md.

IMPORTANT: `--live` POSTs without `dry_run=1` and writes a REAL record into
the user's Liftosaur training history. Never run it without explicit sign-off
from whoever is directing this work.

IMPORTANT: if you just edited backend/python/app/watch_api.py, the running
`garmin-liftosaur-backend.service` will NOT see your change until it is
restarted (`systemctl --user restart garmin-liftosaur-backend.service`). This
tool refuses to proceed if the backend's response doesn't confirm dry_run was
honored (see the capability guard below) specifically because an old process
silently ignoring `?dry_run=1` once wrote a real record into the user's
Liftosaur history during verification.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_PLAN = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "dist", "plan.json")
DEFAULT_COMMS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "source", "Comms.mc")

# The exact program name baked into source/PlanData.mc (Liftosaur rejects a
# history record whose program name does not match exactly).
DEFAULT_PROGRAM = "5/3/1 BBB - Squat/Bench/Deadlift/OHP"

# Safety margin under makeWebRequest's URL length. NOTE: despite the plan's
# assumption of a "documented 2048-character limit", grepping every .html file
# under $SDK/doc (including Toybox/Communications.html, the makeWebRequest
# reference, and Core_Topics/Downloading_Content.html, Authenticated_Web_Services.html,
# HTTPS.html) for "2048", "limit", "maximum", "URL length" and "truncat*" found
# NO documented URL/query length limit anywhere in
# connectiq-sdk-lin-9.2.0-2026-06-09-92a1605b2/doc/. This margin is therefore a
# conservative engineering guess, not a cited SDK fact - flagged for
# adjudication rather than presenting an unverifiable citation.
MAX_URL_LEN = 1800


def urlencode_mirror(s: str) -> str:
    """Mirror of Comms.urlEncode() (embedded/monkeyc/source/Comms.mc).

    Keep this in lockstep with the Monkey C function by hand - there is no
    shared source between Python and Monkey C on this project. If one changes,
    change the other in the same commit.
    """
    hexdigits = "0123456789ABCDEF"
    out = []
    for ch in s:
        v = ord(ch)
        unreserved = (0x41 <= v <= 0x5A or  # A-Z
                     0x61 <= v <= 0x7A or  # a-z
                     0x30 <= v <= 0x39 or  # 0-9
                     v in (0x2D, 0x5F, 0x2E, 0x7E))  # - _ . ~
        if v < 0 or v > 0xFF:
            out.append("_")
        elif unreserved:
            out.append(ch)
        else:
            out.append("%" + hexdigits[(v // 16) % 16] + hexdigits[v % 16])
    return "".join(out)


def build_compact_payload(day: dict, program: str, duration_s: int = 3600) -> str:
    """Exactly WorkoutController.pendingText()'s format:
    day|section|program|duration_s;exercise|weight|reps|amrap;...
    with every set in the day logged (as if the user completed the workout)."""
    head = f"{day['name']}|{day.get('section', '')}|{program}|{duration_s}"
    parts = [head]
    for ex in day["exercises"]:
        for s in ex["sets"]:
            weight = int(round(s["weight"]))
            reps = int(s["reps"])
            amrap = "1" if s["amrap"] else "0"
            parts.append(f"{ex['name']}|{weight}|{reps}|{amrap}")
    return ";".join(parts)


def trailing_number(s: str) -> int:
    """Mirror of Workout.mc's _trailingNumber(): the last run of digits in a
    string, as an int (0 if there are none). "Week 3" -> 3, "Day 4" -> 4."""
    m = re.findall(r"\d+", s)
    return int(m[-1]) if m else 0


def week_and_day(day: dict) -> tuple[int, int]:
    """Mirror of Workout.mc's weekNumber()/dayInWeek() (Task 8): derived from
    the day's section ("Week 3" -> 3) and name ("Day 4" -> 4), not from the
    day's index in the plan list (which spans every week-block)."""
    week = trailing_number(day.get("section", ""))
    day_in_week = trailing_number(day.get("name", ""))
    return (week if week > 0 else 1, day_in_week if day_in_week > 0 else 1)


def check_escaping(raw: str, escaped: str) -> list[str]:
    """Assert the mapping the plan calls out and return problems found (empty
    == clean)."""
    problems = []
    if "%00" in escaped:
        problems.append("found %00 (NUL) in escaped output - the exact bug this tool exists to catch")
    expect = {"|": "%7C", ";": "%3B", "/": "%2F", ",": "%2C", " ": "%20"}
    for ch, code in expect.items():
        if ch in raw and code not in escaped:
            problems.append(f"{ch!r} present in raw text but {code} missing from escaped output")
    return problems


def load_plan(path: str) -> list[dict]:
    with open(path) as fh:
        return json.load(fh)


def default_backend(comms_path: str) -> str:
    with open(comms_path) as fh:
        text = fh.read()
    m = re.search(r'LIFT_BACKEND\s*=\s*"([^"]+)"', text)
    if not m:
        raise SystemExit(f"could not find LIFT_BACKEND in {comms_path}")
    return m.group(1)


def post_dry_run(backend: str, payload: str, live: bool) -> dict:
    escaped = urlencode_mirror(payload)
    qs = "payload=" + escaped if live else "payload=" + escaped + "&dry_run=1"
    url = f"{backend.rstrip('/')}/api/v1/watch/workout?{qs}"
    req = urllib.request.Request(url, method="POST", data=b"")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise SystemExit(f"POST {url[:120]}... -> HTTP {exc.code}: {body[:300]}")
    except OSError as exc:
        raise SystemExit(f"cannot reach {backend}: {exc}")

    if not live:
        # Capability guard (mandatory): a dry-run POST against a backend
        # process that predates the dry_run feature silently ignores the
        # unknown query parameter and performs a REAL write. This has already
        # happened once during verification of this exact tool. Refuse to
        # trust the result - and never retry, since a retry would be a second
        # real write - unless the response proves dry_run was honored.
        if result.get("dry_run") is not True or result.get("recorded") is not False:
            print("REFUSING: backend does not support dry_run (or the response "
                 "doesn't confirm it) - this POST may have written a REAL "
                 "record. Restart garmin-liftosaur-backend.service with the "
                 "current code and re-run.", file=sys.stderr)
            print(f"  response was: {json.dumps(result)[:500]}", file=sys.stderr)
            sys.exit(1)

    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", default=DEFAULT_PLAN,
                    help="plan.json to build payloads from (default: dist/plan.json)")
    ap.add_argument("--comms", default=DEFAULT_COMMS,
                    help="Comms.mc to read LIFT_BACKEND from (default: %(default)s)")
    ap.add_argument("--backend", default=None,
                    help="backend base URL (default: parsed from --comms's LIFT_BACKEND)")
    ap.add_argument("--program", default=DEFAULT_PROGRAM)
    ap.add_argument("--day", default=None,
                    help="day name to POST (default: the first day in the plan)")
    ap.add_argument("--live", action="store_true",
                    help="DANGEROUS: post without dry_run=1, writes a real Liftosaur "
                         "record. Never run without explicit sign-off.")
    args = ap.parse_args()

    plan = load_plan(args.plan)
    if not plan:
        print(f"no days in {args.plan}", file=sys.stderr)
        return 1

    backend = args.backend or default_backend(args.comms)
    print(f"backend: {backend}")
    print(f"plan: {args.plan} ({len(plan)} days)")

    # --- escaping + length check across every day ---------------------------
    failures = []
    print("\nday -> escaped URL length (limit: %d, safety margin under makeWebRequest)" % MAX_URL_LEN)
    for day in plan:
        raw = build_compact_payload(day, args.program)
        escaped = urlencode_mirror(raw)
        url_len = len(f"/api/v1/watch/workout?payload={escaped}&dry_run=1")
        problems = check_escaping(raw, escaped)
        status = "OK" if not problems else "FAIL: " + "; ".join(problems)
        print(f"  {day['name']:40s} {day.get('section', ''):18s} len={url_len:5d}  {status}")
        if problems:
            failures.append(f"{day['name']}: {problems}")
        if url_len > MAX_URL_LEN:
            failures.append(f"{day['name']}: escaped URL length {url_len} exceeds {MAX_URL_LEN}")

    # --- week/dayInWeek table (Task 8) ---------------------------------------
    print("\nday -> week/dayInWeek (derived from section/name, not list index):")
    for day in plan:
        week, day_in_week = week_and_day(day)
        print(f"  {day['name']:40s} {day.get('section', ''):18s} "
             f"-> week {week}, dayInWeek {day_in_week}")

    # sample mapping table (the exact characters from the live payload)
    print("\nsample escaping (must never be %00):")
    for ch in ["|", ";", "/", ",", " ", "-", "5"]:
        print(f"  {ch!r:5s} -> {urlencode_mirror(ch)}")

    if failures:
        print("\nFAILURES:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1

    # --- POST one day to the backend -----------------------------------------
    target = None
    for day in plan:
        if args.day is None or day["name"] == args.day:
            target = day
            break
    if target is None:
        print(f"no day named {args.day!r} in plan", file=sys.stderr)
        return 1

    raw = build_compact_payload(target, args.program)
    expected_sets = raw.count(";")
    print(f"\nposting day {target['name']!r} ({expected_sets} sets, live={args.live}) ...")
    result = post_dry_run(backend, raw, args.live)
    print(json.dumps(result, indent=2)[:2000])

    if args.live:
        print("\n--live was used: a REAL record was written to Liftosaur.")
        return 0

    problems = []
    if result.get("sets") != expected_sets:
        problems.append(f"sets={result.get('sets')} != expected {expected_sets}")
    history = result.get("liftohistory", "")
    for ex in target["exercises"]:
        if ex["name"] not in history:
            problems.append(f"exercise {ex['name']!r} missing from liftohistory")
    for ex in target["exercises"]:
        for s in ex["sets"]:
            weight = int(round(s["weight"]))
            reps = int(s["reps"])
            if f"{reps}" not in history or f"{weight}lb" not in history:
                problems.append(f"set {ex['name']} {weight}lb x{reps} not found in liftohistory")
                break  # one report per exercise is enough noise

    if problems:
        print("\nFAILURES:", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    print("\nOK: round-tripped cleanly, no %00, all sets present in liftohistory.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
