"""Garmin_Liftosaur backend — FastAPI ingestion + physics + rep detection.

Phase 0 scaffold: schema for the /api/v1/sets contract (doc 02) and a /health
endpoint. Physics (Phase 4) and ML rep counting (Phase 5) are stubbed.

Run (dev):
    pip install -r requirements.txt
    uvicorn app.main:app --reload --port 8008
"""
from __future__ import annotations

from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator

from app.physics import compute_physics

API_VERSION = "0.2.0"

app = FastAPI(title="Garmin_Liftosaur Backend", version=API_VERSION)

# Watch-facing routes (plan fetch + workout write-back to Liftosaur).
from app.watch_api import router as watch_router  # noqa: E402

app.include_router(watch_router, prefix="/api/v1")

LBS_TO_KG = 0.45359237


class SetIngest(BaseModel):
    """Flutter → Python payload. Contract: docs/02-backend-api-data-contract.md"""

    user_id: str
    exercise_id: int
    exercise_name: str
    prescribed_weight_lbs: float = Field(gt=0)
    set_number: Optional[int] = None
    started_at: str
    ended_at: str
    sample_rate_hz: int = Field(gt=0, le=200)
    channel_mask: int = Field(gt=0, le=7)
    scale: int = Field(gt=0)
    samples: list[list[int]]  # rows of [x,y,z] fixed-point
    seq_start: Optional[int] = None
    seq_end: Optional[int] = None
    watch_model: Optional[str] = "venu2"
    rep_hint: int = 0

    @field_validator("samples")
    @classmethod
    def check_arity(cls, v: list[list[int]]) -> list[list[int]]:
        for row in v:
            if len(row) != 3:
                raise ValueError("each sample row must be [x,y,z]")
        return v


@app.get("/api/v1/health")
def health() -> dict:
    return {"status": "ok", "version": API_VERSION, "db": "not_configured"}


@app.post("/api/v1/sets")
def ingest_set(payload: SetIngest) -> dict:
    """Accept a completed set and run Phase 4 physics on the raw samples."""
    n = len(payload.samples)
    if n < 4:
        raise HTTPException(status_code=422, detail=f"need >=4 samples, got {n}")

    mass_kg = payload.prescribed_weight_lbs * LBS_TO_KG
    try:
        phys = compute_physics(
            raw_samples=payload.samples,
            scale=payload.scale,
            sample_rate_hz=payload.sample_rate_hz,
            mass_kg=mass_kg,
        )
    except ValueError as exc:  # e.g. filter cutoff >= nyquist at a bad rate
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    warnings = list(phys.warnings)
    if n < payload.sample_rate_hz * 2:
        warnings.append("short_set")

    return {
        "set_id": "pending",
        "status": "ok",
        "n_samples": n,
        "physics": {
            "peak_velocity_m_s": round(phys.peak_velocity_m_s, 4),
            "peak_power_w": round(phys.peak_power_w, 2),
            "mean_power_w": round(phys.mean_power_w, 2),
            "displacement_m": round(phys.displacement_m, 4),
            "duration_s": round(phys.duration_s, 2),
        },
        "rep_count": None,  # Phase 5
        "warnings": warnings or None,
    }
