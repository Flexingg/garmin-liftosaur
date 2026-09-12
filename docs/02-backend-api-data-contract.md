# 02 — Backend API Data Contract (Flutter → Python)

**Owner:** Lead Agent · **Consumers:** Mobile Agent (producer), Data/ML Agent (consumer)
**Status:** v1.0 · Phase 0 / Task 0.2

Base URL: `http://<host>:8008/api/v1` (dev) · All bodies JSON · Responses JSON.

## 1. `POST /api/v1/sets` — ingest a completed set

Request body:

```json
{
  "user_id": "jonathan",
  "exercise_id": 3,
  "exercise_name": "Squat",
  "prescribed_weight_lbs": 225.0,
  "set_number": 2,
  "started_at": "2026-08-28T21:15:00.000Z",
  "ended_at": "2026-08-28T21:15:28.000Z",
  "sample_rate_hz": 25,
  "channel_mask": 7,
  "scale": 1000,
  "samples": [[-120, 980, -44], [0, 1010, -60]],
  "seq_start": 412,
  "seq_end": 440,
  "watch_model": "venu2",
  "rep_hint": 0
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `user_id` | string | yes | stable id; backfilled from Liftosaur account in Phase 3 |
| `exercise_id` | int | yes | matches BLE `exercise_id` |
| `exercise_name` | string | yes | human-readable, for display/ML label |
| `prescribed_weight_lbs` | float | yes | from Liftosaur (Phase 3) |
| `set_number` | int | no | position in the current session |
| `started_at` / `ended_at` | string (ISO8601) | yes | wall-clock bounds |
| `sample_rate_hz` | int | yes | ground-truth rate from the watch |
| `channel_mask` | int | yes | bit0=X bit1=Y bit2=Z |
| `scale` | int | yes | divisor to convert samples → m/s² |
| `samples` | array of `[x,y,z]` | yes | raw int16 fixed-point |
| `seq_start` / `seq_end` | int | no | for gap auditing |
| `watch_model` | string | no | `"venu2"` etc. |
| `rep_hint` | int | no | manual rep count, 0 = auto |

Success response `200`:

```json
{
  "set_id": "9f1c…",
  "status": "ok",
  "n_samples": 700,
  "physics": {
    "peak_velocity_m_s": 1.12,
    "peak_power_w": 345,
    "mean_power_w": 214,
    "displacement_m": 0.42,
    "duration_s": 28.0
  },
  "rep_count": 5,
  "warnings": ["low_sample_rate"]
}
```

Error response `4xx/5xx`:

```json
{ "error": "unprocessable", "detail": "samples missing z channel" }
```

## 2. `GET /api/v1/health` — liveness

```json
{ "status": "ok", "version": "0.1.0", "db": "connected" }
```

## 3. Rep-detection result endpoint (Phase 5)

`GET /api/v1/sets/{set_id}` → full stored set + `rep_count` + per-rep windows.

## 4. Unit conventions (must be enforced everywhere)

- Acceleration in **m/s²** (gravity ≈ +9.81 on Z at rest).
- Time from `started_at` + sample index / `sample_rate_hz`.
- Velocity `v = ∫a·dt` (drift-corrected) in **m/s**.
- Power `P = (m·a)·v` — `m` = total lifted mass (bar + plates) in **kg**, derived from
  `prescribed_weight_lbs` ÷ 2.20462. Result in **watts**.
- Always recompute from the raw samples; never trust a client-supplied `physics` block.

## 5. Validation / acceptance

- A valid request returns `200` with a `physics` block and `rep_count`.
- Physically realistic human bounds (checkpoint 4): `peak_velocity_m_s` roughly 0.5–2.5 m/s;
  `peak_power_w` roughly 200–1500 W for a set. Values like 10,000 W ⇒ filtering/integration bug.
