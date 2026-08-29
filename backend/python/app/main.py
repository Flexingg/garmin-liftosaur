"""Garmin_Liftosaur backend — FastAPI ingestion + physics + rep detection.

Phase 0 scaffold: schema for the /api/v1/sets contract (doc 02) and a /health
endpoint. Physics (Phase 4) and ML rep counting (Phase 5) are stubbed.

Run (dev):
    pip install -r requirements.txt
    uvicorn app.main:app --reload --port 8000
"""
from __future__ import annotations

from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel, Field, field_validator

API_VERSION = "0.1.0"

app = FastAPI(title="Garmin_Liftosaur Backend", version=API_VERSION)


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
    """Accept a completed set. Physics + rep detection wired up in Phase 4/5."""
    n = len(payload.samples)
    return {
        "set_id": "pending",
        "status": "ok",
        "n_samples": n,
        "physics": None,  # Phase 4
        "rep_count": None,  # Phase 5
        "warnings": ["phase4_pending"],
    }
