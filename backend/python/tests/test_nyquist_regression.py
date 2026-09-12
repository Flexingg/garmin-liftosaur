"""Regression tests for the Nyquist clamp in the physics filter.

Context: Garmin's public Sensor API delivers ~20 Hz on a Venu 2S, so Nyquist is
10 Hz. The low-pass design cutoff was a hardcoded 10 Hz, which is *exactly*
Nyquist at that rate — scipy raised, the API returned 422, and every real set
from the watch would have been rejected before any physics ran.

Found by the end-to-end smoke test (mobile/flutter/tool/smoke_e2e.dart) driving
this backend with a synthetic watch-rate set.
"""
from __future__ import annotations

import math

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.physics.kinematics import compute_physics, effective_cutoff

LBS_TO_KG = 0.45359237


def squat_samples(rate_hz: int, seconds: float, scale: int = 1000) -> list[list[int]]:
    """A gravity-dominant ~0.4 Hz squat signal, as the watch would send it."""
    rows: list[list[int]] = []
    for i in range(int(rate_hz * seconds)):
        t = i / rate_hz
        phase = 2 * math.pi * 0.4 * t
        z = 9.81 + 2.4 * math.sin(phase)
        x = 0.45 * math.sin(phase + 0.6)
        y = 0.30 * math.cos(phase)
        rows.append([round(x * scale), round(y * scale), round(z * scale)])
    return rows


def payload(rate_hz: int, seconds: float, weight_lbs: float = 225.0) -> dict:
    rows = squat_samples(rate_hz, seconds)
    return {
        "user_id": "jonathan",
        "exercise_id": 1,
        "exercise_name": "Squat",
        "prescribed_weight_lbs": weight_lbs,
        "set_number": 1,
        "started_at": "2026-09-12T10:00:00.000Z",
        "ended_at": "2026-09-12T10:00:12.000Z",
        "sample_rate_hz": rate_hz,
        "channel_mask": 7,
        "scale": 1000,
        "samples": rows,
        "seq_start": 1,
        "seq_end": 12,
        "watch_model": "venu2s",
        "rep_hint": 0,
    }


class TestEffectiveCutoff:
    def test_passes_through_when_there_is_room(self):
        assert effective_cutoff(10.0, 100) == pytest.approx(10.0)

    def test_clamps_strictly_below_nyquist_at_the_watch_rate(self):
        # 20 Hz => Nyquist 10 Hz. The nominal cutoff must come down.
        cut = effective_cutoff(10.0, 20)
        assert cut < 0.5 * 20
        assert cut == pytest.approx(9.0)

    def test_rejects_nonpositive_rate(self):
        with pytest.raises(ValueError):
            effective_cutoff(10.0, 0)


class TestComputePhysicsAtWatchRates:
    @pytest.mark.parametrize("rate_hz", [20, 25, 50, 100])
    def test_runs_without_raising(self, rate_hz):
        res = compute_physics(
            squat_samples(rate_hz, 12),
            scale=1000,
            sample_rate_hz=rate_hz,
            mass_kg=225 * LBS_TO_KG,
        )
        assert res.duration_s > 0
        assert res.peak_velocity_m_s > 0
        assert res.peak_power_w > 0
        # docs/02 §5: nothing absurd (e.g. the 10,000 W failure mode)
        assert res.peak_velocity_m_s < 5.0
        assert res.peak_power_w < 3000.0

    def test_low_rate_degrades_instead_of_failing(self):
        # 8 Hz is below anything Garmin gives us; it must still not raise.
        res = compute_physics(
            squat_samples(8, 12), scale=1000, sample_rate_hz=8, mass_kg=100.0
        )
        assert res.duration_s > 0


class TestIngestEndpointAtWatchRate:
    def test_20hz_set_is_accepted(self):
        r = TestClient(app).post("/api/v1/sets", json=payload(20, 12))
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "ok"
        assert body["n_samples"] == 240
        assert body["physics"]["peak_velocity_m_s"] > 0
        assert body["physics"]["peak_power_w"] > 0

    def test_25hz_set_is_accepted(self):
        r = TestClient(app).post("/api/v1/sets", json=payload(25, 12))
        assert r.status_code == 200, r.text
