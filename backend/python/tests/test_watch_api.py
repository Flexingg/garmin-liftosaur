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
    discarded = []

    def fake_mcp(name, args, **kw):
        seen["name"] = name
        seen["args"] = args
        return '{"ok":true}'

    monkeypatch.setattr(plan_mod, "mcp_call", fake_mcp)
    # record "111" carries the session's startTime (ms) as its id, which is how
    # the discard finds the workout Liftosaur is holding.
    monkeypatch.setattr(plan_mod, "workout_get_current",
                        lambda: {"startTime": 111000})
    monkeypatch.setattr(plan_mod, "workout_discard",
                        lambda **kw: discarded.append(kw))
    r = client.post("/api/v1/watch/workout/discard", params={"record": "111"})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": True, "id": "111",
                        "rest_discarded": True, "rest_error": ""}
    assert seen["name"] == "delete_history_record"
    assert seen["args"] == {"id": "111"}
    assert discarded == [{"start_time": 111000}]


def test_discard_leaves_another_devices_workout_alone(monkeypatch):
    """A workout the PHONE started must not be thrown away by a watch Discard.

    The old code asked Liftosaur to discard its own guessed startTime, which
    answered 404 for someone else's session - the failure was swallowed, so the
    watch said "discarded" while the workout stayed open in his app.
    """
    discarded = []
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"ok":true}')
    monkeypatch.setattr(plan_mod, "workout_get_current",
                        lambda: {"startTime": 999000})   # not our 111000
    monkeypatch.setattr(plan_mod, "workout_discard",
                        lambda **kw: discarded.append(kw))
    r = client.post("/api/v1/watch/workout/discard", params={"record": "111"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["deleted"] is True        # our history record is still gone
    assert body["rest_discarded"] is False
    assert "different workout is in progress" in body["rest_error"]
    assert discarded == []


def test_discard_with_no_record_is_a_no_op(monkeypatch):
    def must_not_be_called(name, args, **kw):
        raise AssertionError("mcp_call must not run when there is no record")

    monkeypatch.setattr(plan_mod, "mcp_call", must_not_be_called)
    r = client.post("/api/v1/watch/workout/discard", params={"record": ""})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": False, "reason": "no record"}


def test_discard_of_a_missing_record_is_not_an_error(monkeypatch):
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: "Record not found.")
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: None)
    r = client.post("/api/v1/watch/workout/discard", params={"record": "gone"})
    assert r.status_code == 200, r.text
    assert r.json() == {"deleted": True, "id": "gone", "reason": "already gone",
                        "rest_discarded": False, "rest_error": ""}


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
    assert LIVE_NOTE not in seen["text"]


# --- REST API live sync tests -----------------------------------------------

def test_watch_workout_current_none(monkeypatch):
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: None)
    r = client.get("/api/v1/watch/workout/current")
    assert r.status_code == 200
    assert r.json() == {"active": False, "workout": None}


def test_watch_workout_current_active(monkeypatch):
    mock_workout = {
        "startTime": 1780000000000,
        "programId": "prog1",
        "programName": "My Program",
        "dayName": "Day 1",
        "entries": [
            {
                "entryId": "squat_barbell",
                "name": "Squat",
                "sets": [
                    {"setId": "s1", "reps": 5, "weight": "145lb", "completed": {"reps": 5, "weight": "145lb"}, "timer": 90},
                    {"setId": "s2", "reps": 5, "weight": "145lb", "completed": None, "timer": 90}
                ]
            }
        ]
    }
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_workout)
    r = client.get("/api/v1/watch/workout/current")
    assert r.status_code == 200
    data = r.json()
    assert data["active"] is True
    w = data["workout"]
    assert w["dayName"] == "Day 1"
    assert len(w["entries"]) == 1
    sets = w["entries"][0]["sets"]
    assert len(sets) == 2
    assert sets[0]["done"] is True
    assert sets[0]["weight"] == 145
    assert sets[1]["done"] is False


def test_watch_workout_current_with_warmups(monkeypatch):
    mock_workout = {
        "startTime": 1780000000000,
        "programId": "prog1",
        "programName": "My Program",
        "dayName": "Day 1",
        "entries": [
            {
                "entryId": "squat_barbell",
                "name": "Squat",
                "warmupSets": [
                    {"setId": "w1", "reps": 5, "weight": "45lb", "completed": {"reps": 5, "weight": "45lb"}, "timer": 60},
                    {"setId": "w2", "reps": 3, "weight": "135lb", "completed": None, "timer": 60}
                ],
                "sets": [
                    {"setId": "s1", "reps": 5, "weight": "225lb", "completed": None, "timer": 180}
                ]
            }
        ]
    }
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_workout)
    r = client.get("/api/v1/watch/workout/current")
    assert r.status_code == 200
    data = r.json()
    assert data["active"] is True
    entry = data["workout"]["entries"][0]
    assert entry["warmupSets"] == 2
    assert len(entry["sets"]) == 3
    assert entry["sets"][0]["warmup"] is True
    assert entry["sets"][0]["weight"] == 45
    assert entry["sets"][0]["done"] is True
    assert entry["sets"][1]["warmup"] is True
    assert entry["sets"][1]["weight"] == 135
    assert entry["sets"][1]["done"] is False
    assert entry["sets"][2]["warmup"] is False
    assert entry["sets"][2]["weight"] == 225


def test_live_post_triggers_rest_api_sync(monkeypatch):
    """A live post pushes the new set into Liftosaur's ACTIVE workout.

    Updated 2026-09-24 for the batch endpoint: the live path now sends ONE
    POST /api/v1/workout/sets carrying every not-yet-applied set, instead of one
    /workout/set call per set. Per-set calls made a live post take ~1s per
    logged set, which is past the timeout Garmin Connect Mobile puts on a
    watch's request (the watch shows that as "-300") - the assertion below that
    exactly one call happens is the point of the test, not incidental.
    """
    calls = []
    mock_active = {
        "entries": [
            {
                "entryId": "squat_barbell",
                "name": "Squat",
                "sets": [
                    {"setId": "s1", "index": 0, "reps": 5, "weight": "220lb", "completed": None}
                ]
            }
        ]
    }
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_active)
    monkeypatch.setattr(plan_mod, "workout_log_sets", lambda writes, **kw: calls.append(writes))
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')

    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": ""})
    assert r.status_code == 200
    assert r.json()["rest_synced"] is True
    assert len(calls) == 1, "one batch request, not one request per set"
    assert calls[0] == [{
        "entryId": "squat_barbell",
        "setId": "s1",
        "completed": {"reps": 5, "weight": "220lb"},
    }]


def test_live_post_does_not_resend_an_already_completed_set(monkeypatch):
    """Idempotence: the payload always carries the WHOLE workout-so-far, so a
    set Liftosaur already has must not be written again on every later set."""
    calls = []
    mock_active = {
        "entries": [
            {
                "entryId": "squat_barbell",
                "name": "Squat",
                "sets": [
                    {"setId": "s1", "reps": 5, "weight": "220lb",
                     "completed": {"reps": 5, "weight": "220lb"}},
                    {"setId": "s2", "reps": 5, "weight": "250lb", "completed": None},
                ]
            }
        ]
    }
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_active)
    monkeypatch.setattr(plan_mod, "workout_log_sets", lambda writes, **kw: calls.append(writes))
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')

    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0;Squat|250|5|0"),
                            "record": ""})
    assert r.status_code == 200
    assert calls == [[{
        "entryId": "squat_barbell",
        "setId": "s2",
        "completed": {"reps": 5, "weight": "250lb"},
    }]]


def test_live_post_reports_a_rest_failure_instead_of_swallowing_it(monkeypatch):
    """A live-sync failure is surfaced (rest_error + a log line), never hidden.

    This is the HX711-style discipline the project settled on: a silent failure
    here is how "live sync does not work" survived as an unexplained symptom.
    """
    def boom(writes, **kw):
        raise plan_mod.LiftosaurError("POST /workout/sets failed (400): nope")

    monkeypatch.setattr(plan_mod, "workout_get_current",
                        lambda: {"entries": [{"entryId": "e", "name": "Squat",
                                              "sets": [{"setId": "s1", "completed": None}]}]})
    monkeypatch.setattr(plan_mod, "workout_log_sets", boom)
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')

    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"), "record": ""})
    assert r.status_code == 200, "the history record still has to land"
    body = r.json()
    assert body["rest_synced"] is False
    assert "400" in body["rest_error"]


def test_appended_sets_use_a_set_id_liftosaur_accepts():
    """A new setId must match /^[a-z]{6}$/ (apiv1Workout.ts:145-148).

    secrets.token_hex(3) could contain digits, and Liftosaur rejects such an
    append with 400 invalid_input - which the old code swallowed, so appending
    an extra set silently killed the live sync for the rest of the session.
    """
    import re as _re
    for _ in range(50):
        assert _re.fullmatch(r"[a-z]{6}", plan_mod.new_set_id())


def test_finished_post_triggers_rest_api_finish(monkeypatch):
    finished_called = []
    mock_active = {"startTime": 1700000000000}
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_active)
    monkeypatch.setattr(plan_mod, "workout_finish", lambda **kw: finished_called.append(kw))
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')

    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0", started_at=1700000000),
                            "record": "111", "finished": 1})
    assert r.status_code == 200
    assert r.json()["rest_synced"] is True
    assert len(finished_called) == 1
    # the finish must name the startTime Liftosaur is holding: that value becomes
    # the history record's id, and a mismatch is answered 404 (silently, before).
    assert finished_called[0]["start_time"] == 1700000000000


def test_finished_post_does_not_finish_another_devices_workout(monkeypatch):
    """The session in Liftosaur belongs to the phone -> do not finish it.

    Finishing it would end a workout the phone still owns and land a second
    history record for it (different startTime = different id).
    """
    finished_called = []
    monkeypatch.setattr(plan_mod, "workout_get_current",
                        lambda: {"startTime": 999000})
    monkeypatch.setattr(plan_mod, "workout_finish", lambda **kw: finished_called.append(kw))
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"id":"111"}')

    r = client.post("/api/v1/watch/workout/live",
                    params={"payload": _live_payload("Squat|220|5|0"),
                            "record": "111", "finished": 1})
    assert r.status_code == 200, "the watch's own record still has to land"
    body = r.json()
    assert body["rest_synced"] is False
    assert "different workout is in progress" in body["rest_error"]
    assert finished_called == []


def test_discard_triggers_rest_api_discard(monkeypatch):
    discard_called = []
    monkeypatch.setattr(plan_mod, "workout_get_current",
                        lambda: {"startTime": 1700000000000})
    monkeypatch.setattr(plan_mod, "workout_discard", lambda **kw: discard_called.append(kw))
    monkeypatch.setattr(plan_mod, "mcp_call", lambda name, args, **kw: '{"deleted": true}')

    r = client.post("/api/v1/watch/workout/discard", params={"record": "1700000000"})
    assert r.status_code == 200
    assert len(discard_called) == 1
    assert discard_called[0]["start_time"] == 1700000000000


def test_live_payload_with_zero_sets_starts_active_workout(monkeypatch):
    started_called = []
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: None)
    monkeypatch.setattr(plan_mod, "workout_start", lambda **kw: started_called.append(kw) or {"entries": []})

    head = "Day 1|Week 1|5/3/1 BBB - Squat/Bench/Deadlift/OHP|0|1700000000"
    r = client.post("/api/v1/watch/workout/live", params={"payload": head, "record": ""})
    assert r.status_code == 200
    data = r.json()
    assert data["started"] is True
    assert data["sets"] == 0
    assert data["rest_synced"] is True
    assert len(started_called) == 1
    assert started_called[0]["week"] == 1
    assert started_called[0]["day_in_week"] == 1


def test_live_payload_zero_sets_finished_returns_no_record():
    head = "Day 1|Week 1|5/3/1 BBB - Squat/Bench/Deadlift/OHP|0|1700000000"
    r = client.post("/api/v1/watch/workout/live", params={"payload": head, "finished": 1})
    assert r.status_code == 200
    assert r.json()["recorded"] is False
    assert r.json()["sets"] == 0


def test_workout_current_resolves_watch_day_name(monkeypatch):
    mock_active = {
        "startTime": 1700000000000,
        "programId": "p1",
        "programName": "Prog",
        "dayName": "Week 1 - Day 5 - Light Pump (Wed)",
        "dayData": {"week": 1, "dayInWeek": 5},
        "entries": []
    }
    mock_plan = {
        "days": [
            {"name": "Day 5 - Light Pump", "section": "Week 1", "exercises": []}
        ]
    }
    monkeypatch.setattr(plan_mod, "workout_get_current", lambda: mock_active)
    monkeypatch.setattr(plan_mod, "get_plan", lambda: mock_plan)

    r = client.get("/api/v1/watch/workout/current")
    assert r.status_code == 200
    res = r.json()
    assert res["active"] is True
    assert res["workout"]["dayName"] == "Day 5 - Light Pump"
    assert res["workout"]["rawDayName"] == "Week 1 - Day 5 - Light Pump (Wed)"


# --------------------------------------------------- endpoint diagnostics (2026-09-24)

def test_watch_health_answers_without_touching_liftosaur(monkeypatch):
    """The watch's endpoint probe must answer even when Liftosaur is down:
    "is my configured backend URL reachable?" is a different question from
    "can the backend reach Liftosaur?", and it is the reachable-URL one that
    a rotated tunnel hostname breaks (the watch sees CIQ/GCM's -300)."""
    def explode(*a, **kw):
        raise AssertionError("health must not call Liftosaur")

    monkeypatch.setattr(plan_mod, "mcp_call", explode)
    monkeypatch.setattr(plan_mod, "rest_call", explode)
    r = client.get("/api/v1/watch/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "garmin-liftosaur"


def test_plan_trailing_slash_in_program_does_not_500(monkeypatch):
    """A base URL configured with a trailing slash made every watch URL carry
    one, and `?program=<id>/` used to answer 500 (json.loads on Liftosaur's
    'not found' text). It is stripped now; the value never reaches Liftosaur."""
    seen = []

    def fake_get_plan(program_id, force=False):
        seen.append(program_id)
        return {"program": "P", "days": [{"name": "Day 1", "section": "Week 1"}]}

    monkeypatch.setattr(plan_mod, "get_plan", fake_get_plan)
    r = client.get("/api/v1/watch/plan", params={"program": "gjedbyiv/"})
    assert r.status_code == 200
    assert seen == ["gjedbyiv"]


def test_plan_unknown_program_is_a_404_not_a_503(monkeypatch):
    """404 (your program id is wrong) and 503 (Liftosaur unreachable) are
    different problems for the user, so they get different status codes."""
    def not_found(program_id, force=False):
        raise plan_mod.ProgramNotFound("program 'nope' not found")

    monkeypatch.setattr(plan_mod, "get_plan", not_found)
    r = client.get("/api/v1/watch/plan", params={"program": "nope"})
    assert r.status_code == 404

    def unreachable(program_id, force=False):
        raise plan_mod.LiftosaurError("network failed")

    monkeypatch.setattr(plan_mod, "get_plan", unreachable)
    r = client.get("/api/v1/watch/plan", params={"program": "nope"})
    assert r.status_code == 503


def test_build_from_liftosaur_rejects_a_non_json_reply(monkeypatch):
    """Liftosaur answers a bad program lookup with plain text at HTTP 200;
    that must surface as ProgramNotFound, not a JSONDecodeError 500."""
    monkeypatch.setattr(plan_mod, "mcp_call",
                        lambda name, args, **kw: "Program 'x/' not found")
    try:
        plan_mod.build_from_liftosaur("")
    except plan_mod.ProgramNotFound as exc:
        assert "not found" in str(exc)
    else:
        raise AssertionError("expected ProgramNotFound")


