"""Watch API tests: the Liftohistory write-back format and the two endpoints.

The format matters more than it looks: Liftosaur rejects a malformed history
record, and a failed write means the user's session is lost. So the exact text
is asserted here rather than eyeballed.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import plan as plan_mod
from app.main import app
from app.watch_api import LoggedSet, WorkoutIn, to_liftohistory

client = TestClient(app)


@pytest.fixture(autouse=True)
def _reset_live_sync_state():
    """The live-sync in-memory bookkeeping (record id -> stamp / set count) is
    module-level state so it survives a backend restart's absence gracefully
    in production, but that also means it survives between tests unless reset
    - without this, a record id reused across two test functions (e.g. "111")
    would carry a stale set count from an earlier test."""
    from app import watch_api
    watch_api._LIVE_STAMPS.clear()
    watch_api._LIVE_SET_COUNTS.clear()
    yield


def _set(ex, w, reps, amrap=False):
    return LoggedSet(exercise=ex, weight=w, reps=reps, amrap=amrap)


def test_53_1_wave_is_not_grouped_together():
    """An ascending wave must stay as separate sets: 220/250/285 are not '3x5'."""
    w = WorkoutIn(day="Day 1", program="5/3/1 BBB", duration_s=3600,
                  finished_at=1_700_000_000,
                  sets=[_set("Squat", 220, 5), _set("Squat", 250, 5),
                        _set("Squat", 285, 5, amrap=True),
                        _set("Squat", 170, 10), _set("Squat", 170, 10)])
    text = to_liftohistory(w)
    assert "1x5 220lb, 1x5 250lb, 1x5+ 285lb, 2x10 170lb" in text
    # an AMRAP set carries '+'
    assert "1x5+ 285lb" in text
    # units are always explicit
    assert "lb" in text and "kg" not in text


def test_identical_sets_are_collapsed():
    w = WorkoutIn(day="Day 3", duration_s=60,
                  sets=[_set("Good Morning", 65, 8) for _ in range(3)])
    assert "3x8 65lb" in to_liftohistory(w)


def test_header_and_exercise_order_follow_the_workout():
    w = WorkoutIn(day="Day 1", program="5/3/1 BBB", section="Week 1",
                  week=1, day_in_week=1, duration_s=3700,
                  finished_at=1_700_000_000,
                  sets=[_set("Squat", 220, 5), _set("Romanian Deadlift", 135, 8),
                        _set("Squat", 250, 5)])
    text = to_liftohistory(w)
    assert text.startswith("2023-11-14T22:13:20Z / program: \"5/3/1 BBB\"")
    assert '/ dayName: "Day 1"' in text
    assert "/ week: 1 / dayInWeek: 1 / duration: 3700s" in text
    assert text.rstrip().endswith("}")
    # first-seen order wins, and both Squat sets land on one line
    assert text.index("Squat") < text.index("Romanian Deadlift")
    assert "Squat / 1x5 220lb, 1x5 250lb" in text


def test_targets_come_from_the_plan_when_available():
    plan = {"days": [{"name": "Day 1", "exercises": [
        {"name": "Squat", "rest": 180, "sets": [
            {"reps": 5, "weight": 220, "amrap": False, "rest": 180},
            {"reps": 5, "weight": 285, "amrap": True, "rest": 180}]}]}]}
    w = WorkoutIn(day="Day 1", duration_s=10, sets=[_set("Squat", 220, 5)])
    text = to_liftohistory(w, plan)
    assert "/ target: 5 220lb 180s, 5+ 285lb 180s" in text


def test_plan_endpoint_returns_the_compiled_plan(monkeypatch):
    monkeypatch.setattr(plan_mod, "get_plan",
                        lambda program_id="current", force=False: {"program": "P", "days": []})
    r = client.get("/api/v1/watch/plan")
    assert r.status_code == 200
    assert r.json()["program"] == "P"


def test_plan_endpoint_503_so_the_watch_falls_back(monkeypatch):
    """A 503 is meaningful: the watch keeps using its baked-in plan."""
    def boom(program_id="current", force=False):
        raise plan_mod.LiftosaurError("liftosaur down")
    monkeypatch.setattr(plan_mod, "get_plan", boom)
    r = client.get("/api/v1/watch/plan")
    assert r.status_code == 503


def test_workout_endpoint_writes_liftohistory(monkeypatch):
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["name"] = name
        seen["text"] = args["text"]
        return "{\"id\":\"abc\"}"

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout", json={
        "day": "Day 1", "program": "5/3/1 BBB", "duration_s": 3600,
        "sets": [{"exercise": "Squat", "weight": 220, "reps": 5},
                 {"exercise": "Squat", "weight": 285, "reps": 5, "amrap": True}]})
    assert r.status_code == 200, r.text
    assert r.json()["recorded"] is True
    assert seen["name"] == "create_history_record"
    assert "1x5 220lb, 1x5+ 285lb" in seen["text"]


def test_workout_endpoint_rejects_an_empty_session(monkeypatch):
    r = client.post("/api/v1/watch/workout", json={"day": "Day 1", "sets": []})
    assert r.status_code == 422


def test_workout_endpoint_reports_liftosaur_failure(monkeypatch):
    def boom(name, args, **kw):
        raise plan_mod.LiftosaurError("create_history_record failed")
    monkeypatch.setattr(plan_mod, "mcp_call", boom)
    r = client.post("/api/v1/watch/workout", json={
        "day": "Day 1", "sets": [{"exercise": "Squat", "weight": 220, "reps": 5}]})
    assert r.status_code == 502


def test_rejected_record_is_not_reported_as_success(monkeypatch):
    """Liftosaur returns a rejection as CONTENT with a 200 ('Program "X" not
    found'). Reporting that as recorded=True would tell the user their workout
    saved when it was thrown away."""
    monkeypatch.setattr(plan_mod, "mcp_call",
                        lambda name, args, **kw: 'Program "Nope" not found.')
    r = client.post("/api/v1/watch/workout", json={
        "day": "Day 1", "program": "Nope",
        "sets": [{"exercise": "Squat", "weight": 220, "reps": 5}]})
    assert r.status_code == 502
    assert "not found" in r.json()["detail"]


def test_successful_write_returns_the_record_id(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call",
                        lambda name, args, **kw: '{"id":1789286774000,"text":"..."}')
    r = client.post("/api/v1/watch/workout", json={
        "day": "Day 1", "sets": [{"exercise": "Squat", "weight": 220, "reps": 5}]})
    assert r.status_code == 200
    assert r.json()["id"] == 1789286774000


def test_plan_section_filter(monkeypatch):
    monkeypatch.setattr(plan_mod, "get_plan", lambda program_id="current", force=False: {
        "program": "P", "sections": ["Week 1", "Week 4 - Deload"],
        "days": [{"name": "Day 1", "section": "Week 1", "exercises": []},
                 {"name": "Day 1", "section": "Week 4 - Deload", "exercises": []}]})
    r = client.get("/api/v1/watch/plan", params={"section": "Week 1"})
    assert r.status_code == 200
    assert len(r.json()["days"]) == 1
    assert r.json()["days"][0]["section"] == "Week 1"
    # an unknown section is a 404, not an empty plan the watch would trust
    assert client.get("/api/v1/watch/plan", params={"section": "Nope"}).status_code == 404


def test_programs_endpoint(monkeypatch):
    monkeypatch.setattr(plan_mod, "list_programs",
                        lambda: [{"id": "abc", "name": "5/3/1", "isCurrent": True}])
    r = client.get("/api/v1/watch/programs")
    assert r.status_code == 200
    assert r.json()["programs"][0]["name"] == "5/3/1"


def test_plan_can_target_a_named_program(monkeypatch):
    """The watch picks a program by id; the endpoint must pass it through."""
    seen = {}

    def fake_get_plan(program_id="current", force=False):
        seen["program"] = program_id
        return {"program": program_id, "days": [], "sections": []}

    monkeypatch.setattr(plan_mod, "get_plan", fake_get_plan)
    r = client.get("/api/v1/watch/plan", params={"program": "gjedbyiv"})
    assert r.status_code == 200
    assert seen["program"] == "gjedbyiv"


def test_plan_returns_every_section_when_unfiltered(monkeypatch):
    """Regression: the watch was only ever given Week 1. Without ?section the
    response must carry all days, deload included."""
    monkeypatch.setattr(plan_mod, "get_plan", lambda program_id="current", force=False: {
        "program": "P", "sections": ["Week 1", "Week 4 - Deload"],
        "days": [{"name": "Day 1", "section": "Week 1", "exercises": []},
                 {"name": "Day 1", "section": "Week 4 - Deload", "exercises": []},
                 {"name": "Day 2", "section": "Week 4 - Deload", "exercises": []}]})
    r = client.get("/api/v1/watch/plan")
    assert r.status_code == 200
    assert len(r.json()["days"]) == 3


# --- exercise history (the info screen's data) ------------------------------

HISTORY_FIXTURE = (
    '{"records":['
    '{"id":1,"text":"2026-09-13 08:37:19 +00:00 / program: \\"P\\" / dayName: \\"Week 3 - Day 4\\"'
    ' / week: 3 / dayInWeek: 4 / duration: 3809s / exercises: {\\n'
    '  Overhead Press / 1x5 120lb, 1x3 140lb, 1x1 155lb, 2x10 95lb'
    ' / warmup: 1x5 60lb / target: 1x5 120lb 180s\\n'
    '  Reverse Lunge, Barbell / 3x8|8 100lb / target: 3x8 100lb 90s\\n'
    '}"},'
    '{"id":2,"text":"2026-09-10 07:56:00 +00:00 / program: \\"P\\" / dayName: \\"Day 1\\"'
    ' / week: 2 / duration: 3000s / exercises: {\\n'
    '  Squat, Barbell / 1x5 240lb, 1x3 275lb, 1x2 305lb / target: 1x5 240lb\\n'
    '}"}'
    ']}'
)


def test_exercise_history_reads_the_json_envelope(monkeypatch):
    """get_history returns {"records":[{"text": <liftohistory>}]} - not raw text.
    Getting this wrong silently reported "no previous session" for everything."""
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: HISTORY_FIXTURE)
    h = plan_mod.exercise_history("Overhead Press")
    last = h["last"]
    assert last is not None
    assert last["date"].startswith("2026-09-13")
    # the 2x10 95lb group is expanded to individual sets
    assert [(s["reps"], s["weight"]) for s in last["sets"]] == [
        (5, 120), (3, 140), (1, 155), (10, 95), (10, 95)]
    assert last["top_weight"] == 155
    # Epley on 155x1 is 160
    assert last["e1rm"] == 160


def test_exercise_history_matches_names_without_punctuation(monkeypatch):
    """Display names carry spaces/commas; the lookup must normalise them."""
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: HISTORY_FIXTURE)
    assert plan_mod.exercise_history("Reverse Lunge, Barbell")["last"] is not None
    assert plan_mod.exercise_history("Squat")["last"] is not None


def test_exercise_history_handles_an_unknown_exercise(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: HISTORY_FIXTURE)
    h = plan_mod.exercise_history("Nonexistent Lift")
    assert h["last"] is None
    assert h["recent"] == []


def test_exercise_endpoint(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: HISTORY_FIXTURE)
    r = client.get("/api/v1/watch/exercise", params={"name": "Squat"})
    assert r.status_code == 200
    assert r.json()["last"]["top_weight"] == 305


def test_exercise_history_recent_is_capped_and_small(monkeypatch):
    """The history screen (Task 7) is a scrolling list fed by 'recent', not the
    5-line fixed block it used to be - the server now sends up to 12 sessions
    instead of 5. This travels to the watch over the https tunnel, so it must
    stay small even at the new cap."""
    import json as _json

    records = []
    for i in range(15):  # more than the 12-session cap
        records.append({
            "id": i,
            "text": (f"2026-0{(i % 9) + 1}-10 08:00:00 +00:00 / program: \"P\" "
                    f"/ dayName: \"Day 1\" / week: 1 / dayInWeek: 1 "
                    f"/ duration: 3000s / exercises: {{\n"
                    f"  Squat / 1x5 {220 + i}lb, 1x3 {250 + i}lb, 1x2 {280 + i}lb "
                    f"/ target: 1x5 {220 + i}lb\n"
                    f"}}"),
        })
    fixture = _json.dumps({"records": records})
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: fixture)

    h = plan_mod.exercise_history("Squat")
    assert len(h["recent"]) == 12  # capped, not all 15

    r = client.get("/api/v1/watch/exercise", params={"name": "Squat"})
    assert r.status_code == 200
    body = r.json()
    assert len(body["recent"]) == 12
    size = len(_json.dumps(body).encode())
    assert size < 4000, f"exercise_history JSON is {size} bytes, over the 4000-byte budget"


# --- the watch's compact payload (form-encoded) -----------------------------

def test_parse_compact_round_trips():
    """The watch cannot build JSON, so it ships this compact string."""
    from app.watch_api import parse_compact
    w = parse_compact("Day 1|Week 1|5/3/1 BBB|4200;"
                      "Squat|220|5|0;Squat|250|5|0;Squat|285|6|1;"
                      "Romanian Deadlift, Barbell|135|8|0")
    assert w.day == "Day 1"
    assert w.program == "5/3/1 BBB"
    assert w.duration_s == 4200
    assert [(x.exercise, x.weight, x.reps, x.amrap) for x in w.sets] == [
        ("Squat", 220, 5, False), ("Squat", 250, 5, False),
        ("Squat", 285, 6, True), ("Romanian Deadlift, Barbell", 135, 8, False)]


def test_parse_compact_rejects_a_malformed_header():
    from app.watch_api import parse_compact
    import pytest
    with pytest.raises(ValueError):
        parse_compact("garbage")


def test_workout_endpoint_accepts_the_watch_form_payload(monkeypatch):
    """makeWebRequest can only POST flat scalars, so the watch sends `payload`
    form-encoded. That path must work end to end."""
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["text"] = args["text"]
        return '{"id":123}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout",
                    data={"payload": "Day 1|Week 1|5/3/1 BBB|4200;"
                                     "Squat|220|5|0;Squat|285|6|1"})
    assert r.status_code == 200, r.text
    assert r.json()["recorded"] is True
    assert r.json()["id"] == 123
    assert "Squat / 1x5 220lb, 1x6+ 285lb" in seen["text"]


def test_workout_endpoint_rejects_an_empty_form_payload():
    r = client.post("/api/v1/watch/workout", data={"nope": "x"})
    assert r.status_code == 422


# --- week-aware resolution (why only weeks 1 and 4 used to appear) -----------

WEEK_PROGRAM = """# Week 1
## Day 1
main / used: none / 1x5 65%, 1x5 75%, 1x5+ 85% / 180s

Squat, Barbell[1-4] / ...main
Accessory[1-3] / 3x8 / 100lb 90s

## Day 2
Bench Press[1-4] / ...main

# Week 2
## Day 1
main / used: none / 1x3 70%, 1x3 80%, 1x3+ 90% / 180s

## Day 2
"""


def test_later_weeks_inherit_days_but_override_blocks():
    """The real program's weeks 2-3 contain ONLY a new "main" block and empty day
    sections. Empty days must inherit the previous week's exercises, and the
    block must change the weights - that is the whole 5/3/1 wave. Treating each
    week standalone silently dropped those days (only weeks 1 and 4 appeared)."""
    plan, warnings = plan_mod.build_by_week(WEEK_PROGRAM, {"squat": 300.0,
                                                          "benchpress": 200.0})
    assert warnings == []
    days = {(d["section"], d["name"]): d for d in plan}
    # week 2 day 2 has no entries of its own -> inherited from week 1
    assert ("Week 2", "Day 2") in days
    # week 1: 65/75/85 of 300
    w1 = [s["weight"] for s in days[("Week 1", "Day 1")]["exercises"][0]["sets"]]
    assert w1 == [195, 225, 255]
    # week 2: 70/80/90 of 300 - same exercise line, new block
    w2 = [s["weight"] for s in days[("Week 2", "Day 1")]["exercises"][0]["sets"]]
    assert w2 == [210, 240, 270]
    # the [1-3] accessory is not in week 4's list
    assert len(days[("Week 1", "Day 1")]["exercises"]) == 2


def test_week_selector_limits_an_entry():
    """[1-3] must not leak into week 4."""
    text = WEEK_PROGRAM + "\n# Week 4\n## Day 1\nSquat, Barbell[1-4] / 1x5 40%\n"
    plan_, _ = plan_mod.build_by_week(text, {"squat": 300.0})
    w4 = [d for d in plan_ if d["section"] == "Week 4"][0]
    names = [e["name"] for e in w4["exercises"]]
    assert "Accessory" not in names


def test_workout_endpoint_accepts_the_payload_in_the_query_string(monkeypatch):
    """The watch now sends NO body at all - the parameters-Dictionary path
    crashed twice on the device ("Unexpected Type Error" at the makeWebRequest
    call). The workout rides in the query string instead."""
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["text"] = args["text"]
        return '{"id":999}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout",
                    params={"payload": "Day 1|Week 1|5/3/1 BBB|4200;"
                                       "Squat|220|5|0;Squat|285|6|1"})
    assert r.status_code == 200, r.text
    assert r.json()["id"] == 999
    assert "Squat / 1x5 220lb, 1x6+ 285lb" in seen["text"]


def test_query_payload_survives_url_escaping():
    """| ; , + and spaces are escaped by the watch's urlEncode and must decode
    back to the same compact payload."""
    import urllib.parse
    from app.watch_api import parse_compact
    raw = "Day 1|Week 1|5/3/1 BBB|4200;Romanian Deadlift, Barbell|135|8|0"
    escaped = urllib.parse.quote(raw, safe="")
    decoded = urllib.parse.unquote(escaped)
    w = parse_compact(decoded)
    assert w.sets[0].exercise == "Romanian Deadlift, Barbell"
    assert w.program == "5/3/1 BBB"


# --- dry-run mode (verify the save path without writing to Liftosaur) -------

def test_dry_run_renders_without_writing(monkeypatch):
    """?dry_run=1 must render the Liftohistory text and must NOT call the MCP
    write - this is how the payload is proven end to end without littering the
    user's real training history."""
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run in dry-run mode")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    raw = ("Day 1|Week 1|5/3/1 BBB - Squat/Bench/Deadlift/OHP|3600;"
          "Squat|220|5|0;Squat|250|5|0")
    # the test client encodes the query string itself (like the watch's
    # urlEncode does over HTTP); passing raw text here mirrors that.
    r = client.post("/api/v1/watch/workout",
                    params={"payload": raw, "dry_run": 1})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["recorded"] is False
    assert body["dry_run"] is True
    assert body["sets"] == 2
    assert 'program: "5/3/1 BBB - Squat/Bench/Deadlift/OHP"' in body["liftohistory"]
    assert "Squat / 1x5 220lb, 1x5 250lb" in body["liftohistory"]


def test_nul_separated_payload_is_rejected_with_a_clear_error():
    """Regression marker for the Comms.urlEncode bug (commit d084048): every
    '|', ';' and '/' in the payload was emitted as a NUL byte instead of its
    percent-escape, so the header split into one field and the real save
    attempts in the field all failed with 422. This is that exact shape."""
    raw = ("Day 3|Week 1|5/3/1 BBB - Squat/Bench/Deadlift/OHP|27138;"
          "Deadlift|210|5|0;Deadlift|235|5|0")
    corrupted = raw.replace("|", "\x00").replace("/", "\x00").replace(";", "\x00")
    r = client.post("/api/v1/watch/workout", params={"payload": corrupted})
    assert r.status_code == 422
    assert "malformed" in r.json()["detail"]


# --- live sync (create-then-update, one push per completed set) ------------

def _live_payload(sets_suffix, started_at=None, duration=120):
    head = f"Day 1|Week 1|5/3/1 BBB - Squat/Bench/Deadlift/OHP|{duration}"
    if started_at is not None:
        head += f"|{started_at}"
    return head + ";" + sets_suffix


def test_live_payload_without_a_record_creates_a_record(monkeypatch):
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["name"] = name
        seen["text"] = args["text"]
        return '{"id":"111"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": ""})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["created"] is True
    assert body["id"] == "111"
    assert seen["name"] == "create_history_record"
    assert "Squat / 1x5 220lb" in seen["text"]


def test_live_payload_with_a_record_updates_it(monkeypatch):
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["name"] = name
        seen["args"] = args
        return '{"id":"111"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0;Squat|250|5|0"),
                            "record": "111"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["updated"] is True
    assert body["id"] == "111"
    assert seen["name"] == "update_history_record"
    assert seen["args"]["id"] == "111"
    # a full replacement, not a delta - both sets present in one text
    assert "Squat / 1x5 220lb, 1x5 250lb" in seen["args"]["text"]


def test_update_falls_back_to_create_when_the_record_is_gone(monkeypatch):
    calls = []

    def fake_mcp(name, args, **kw):
        calls.append(name)
        if name == "update_history_record":
            return "Record not found."
        return '{"id":"222"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": "stale-id"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["created"] is True
    assert body["id"] == "222"
    assert calls == ["update_history_record", "create_history_record"]


def test_a_stale_shorter_payload_does_not_shrink_the_record(monkeypatch):
    def fake_mcp(name, args, **kw):
        return '{"id":"111"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    # first: 3 sets applied
    r1 = client.post("/api/v1/watch/workout/live", params={
        "payload": _live_payload("Squat|220|5|0;Squat|250|5|0;Squat|285|5|0"),
        "record": "111"})
    assert r1.status_code == 200, r1.text
    assert r1.json()["updated"] is True

    # then: a late/out-of-order request with only 1 set must not write
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run for a stale payload")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    r2 = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": "111"})
    assert r2.status_code == 200, r2.text
    assert r2.json()["skipped"] == "stale"


def test_live_timestamp_is_stable_across_updates(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')
    r1 = client.post("/api/v1/watch/workout/live", params={
        "payload": _live_payload("Squat|220|5|0", started_at=1_700_000_000),
        "record": "", "dry_run": 1})
    r2 = client.post("/api/v1/watch/workout/live", params={
        "payload": _live_payload("Squat|220|5|0;Squat|250|5|0", started_at=1_700_000_000),
        "record": "111", "dry_run": 1})
    # line 0 is now the LIVE_NOTE marker (to_liftohistory(..., live=True),
    # the default for /live) - the date header is the next line.
    line1 = r1.json()["liftohistory"].splitlines()[1]
    line2 = r2.json()["liftohistory"].splitlines()[1]
    assert line1.split(" / ")[0] == line2.split(" / ")[0]
    assert line1.startswith("2023-11-14T22:13:20Z")


def test_live_payload_without_started_at_still_parses(monkeypatch):
    """A 4-field header (no 5th started_at field) must still parse."""
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": "",
                            "dry_run": 1})
    assert r.status_code == 200, r.text
    assert r.json()["sets"] == 1


def test_live_dry_run_writes_nothing(monkeypatch):
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run in dry-run mode")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": "",
                            "dry_run": 1})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["recorded"] is False
    assert body["dry_run"] is True
    assert body["id"] == "dry"


# --- discard (delete the live record) ---------------------------------------

def test_discard_deletes_the_record(monkeypatch):
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["name"] = name
        seen["args"] = args
        return '{"ok":true}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/discard", params={"record": "111"})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": True, "id": "111"}
    assert seen["name"] == "delete_history_record"
    assert seen["args"] == {"id": "111"}


def test_discard_with_no_record_is_a_no_op(monkeypatch):
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run when there is no record")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    r = client.post("/api/v1/watch/workout/discard", params={"record": ""})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": False, "reason": "no record"}


def test_discard_of_a_missing_record_is_not_an_error(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: "Record not found.")
    r = client.post("/api/v1/watch/workout/discard", params={"record": "gone"})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": True, "id": "gone", "reason": "already gone"}


def test_discard_dry_run_writes_nothing(monkeypatch):
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run in dry-run mode")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    r = client.post("/api/v1/watch/workout/discard", params={"record": "111", "dry_run": 1})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": False, "dry_run": True, "id": "111"}


def test_parse_compact_roundtrip_all_days():
    """Every day in the real compiled plan (dist/plan.json, the source for
    PlanData.mc) must round-trip through the compact-payload encoding the
    watch actually sends: build the payload the same way pendingText() does,
    URL-escape it, decode it, and parse it back."""
    import json
    import urllib.parse
    from pathlib import Path
    from app.watch_api import parse_compact

    plan_path = Path(__file__).resolve().parents[3] / "dist" / "plan.json"
    days = json.loads(plan_path.read_text())
    assert len(days) > 0

    for day in days:
        expected = []
        set_fields = []
        for ex in day["exercises"]:
            for s in ex["sets"]:
                weight = int(round(s["weight"]))
                reps = int(s["reps"])
                amrap = bool(s["amrap"])
                expected.append((ex["name"], weight, reps, amrap))
                set_fields.append(f"{ex['name']}|{weight}|{reps}|{'1' if amrap else '0'}")
        if not set_fields:
            continue
        raw = (f"{day['name']}|{day.get('section', '')}|Program|3600;"
              + ";".join(set_fields))
        escaped = urllib.parse.quote(raw, safe="")
        decoded = urllib.parse.unquote(escaped)
        w = parse_compact(decoded)
        assert [(s.exercise, s.weight, s.reps, s.amrap) for s in w.sets] == [
            (name, float(weight), reps, amrap) for name, weight, reps, amrap in expected]


# --- create-as-live (Part B) --------------------------------------------------
#
# Real "no endTime" is not achievable through the MCP write surface (see the
# module docstring in app/watch_api.py) - these tests cover the closest
# approximation this backend actually implements: a LIVE_NOTE marker in the
# record's notes, present while syncing and dropped only on finished=1.
#
# The attach-on-launch feature that used to sit next to these tests
# (`/watch/workout/active`, `parse_liftohistory_record`) was removed
# 2026-09-19: real-device testing confirmed a workout open in the phone app
# is not discoverable through the history API at all, so it never achieved
# what it was built for. See the module docstring in app/watch_api.py for the
# full storage-sync investigation that settled this.

from app.watch_api import LIVE_NOTE


def test_live_post_defaults_to_marking_the_record_live(monkeypatch):
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["text"] = args["text"]
        return '{"id":"111"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": ""})
    assert r.status_code == 200, r.text
    assert seen["text"].startswith(f"// {LIVE_NOTE}")


def test_finished_post_drops_the_live_marker(monkeypatch):
    """This is the watch's real finish path (Comms.mc postWorkout() posts
    here with finished=1, not to /watch/workout) - the only "done" signal
    this API can produce, since endTime can't be omitted either way."""
    seen = {}

    def fake_mcp(name, args, **kw):
        seen["text"] = args["text"]
        return '{"id":"111"}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": "",
                            "finished": 1})
    assert r.status_code == 200, r.text
    assert LIVE_NOTE not in seen["text"]

