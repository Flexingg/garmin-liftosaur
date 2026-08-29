"""API tests for POST /api/v1/sets and GET /api/v1/health (contract 02)."""
from __future__ import annotations

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.synthetic import make_squat

client = TestClient(app)


def _payload(**overrides) -> dict:
    data = make_squat()
    base = {
        "user_id": "jonathan",
        "exercise_id": 3,
        "exercise_name": "Squat",
        "prescribed_weight_lbs": 225.0,
        "set_number": 2,
        "started_at": "2026-08-28T21:15:00.000Z",
        "ended_at": "2026-08-28T21:15:13.000Z",
        "sample_rate_hz": data["rate"],
        "channel_mask": 7,
        "scale": data["scale"],
        "samples": data["raw"].tolist(),
        "seq_start": 412,
        "seq_end": 440,
        "watch_model": "venu2",
        "rep_hint": 0,
    }
    base.update(overrides)
    return base


def test_health():
    resp = client.get("/api/v1/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["version"].startswith("0.")


def test_ingest_valid_set_returns_physics():
    resp = client.post("/api/v1/sets", json=_payload())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "ok"
    assert body["n_samples"] == len(make_squat()["raw"])
    assert body["rep_count"] is None  # Phase 5
    phys = body["physics"]
    assert 0.5 <= phys["peak_velocity_m_s"] <= 2.5
    assert 200.0 <= phys["peak_power_w"] <= 1500.0
    assert "phase4_pending" not in (body.get("warnings") or [])


def test_rejects_non_3_col_samples():
    payload = _payload()
    payload["samples"] = [[1, 2], [3, 4]]  # not [x,y,z]
    resp = client.post("/api/v1/sets", json=payload)
    assert resp.status_code == 422


def test_rejects_zero_weight():
    resp = client.post("/api/v1/sets", json=_payload(prescribed_weight_lbs=0))
    assert resp.status_code == 422


def test_rejects_too_few_samples():
    payload = _payload()
    payload["samples"] = [[0, 0, 9800], [0, 0, 9800], [0, 0, 9800]]
    resp = client.post("/api/v1/sets", json=payload)
    assert resp.status_code == 422
