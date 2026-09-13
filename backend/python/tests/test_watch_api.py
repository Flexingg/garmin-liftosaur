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
