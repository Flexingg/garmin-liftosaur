"""Suite-wide guard: no test may touch the owner's real Liftosaur account.

Found on 2026-09-24 while proving the live-sync path end to end: several
`live` tests only stubbed `plan_mod.mcp_call`, but `/watch/workout/live` also
calls the Liftosaur **REST** API (`_sync_live_to_liftosaur` ->
`workout_get_current`, then `workout_start` when nothing is in progress). So
running the suite silently STARTED a phantom workout in the owner's account,
with the tests' own weights in it - the owner would find an "in progress"
workout in his Liftosaur app that he never started, and it stayed there until
something discarded it.

The autouse fixture below replaces the single REST entry point
(`app.plan.rest_call`) with a refusal, so the suite is hermetic. Tests that
want to exercise the REST leg patch `plan_mod.workout_*` themselves; a test
that reaches this refusal is reported (LiftosaurError is what the production
code already raises for a transport failure, so behaviour stays realistic).
"""
from __future__ import annotations

import pytest

from app import plan as plan_mod


@pytest.fixture(autouse=True)
def _no_live_liftosaur_rest(monkeypatch):
    def _refuse(method: str, path: str, *args, **kwargs):
        raise plan_mod.LiftosaurError(
            f"test attempted a LIVE Liftosaur REST call: {method} {path} "
            "(stub plan_mod.workout_* instead - see tests/conftest.py)")

    monkeypatch.setattr(plan_mod, "rest_call", _refuse)
    yield
