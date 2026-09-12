# Backend workspace (Python — FastAPI physics + rep detection)

Owner: Data/ML Agent.

```bash
cd /c/RandallEngineering/Garmin_Liftosaur/backend/python
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt      # (Windows)
.venv/Scripts/uvicorn app.main:app --reload --port 8008
curl http://127.0.0.1:8008/api/v1/health
```

## Phases

- **Phase 4** — `app/physics/kinematics.py`: low-pass filter, gravity isolation,
  integrate acceleration → velocity, compute power. Units per contract doc 02 §4.
  Live in `POST /api/v1/sets`. ✅ implemented & tested
- **Phase 5** — `app/ml/` rep detection: DB storage, peak detection on Z-axis zero-crossings,
  Random Forest / 1D-CNN classifier.

## Tests

```bash
.venv/bin/pip install pytest httpx
.venv/bin/python -m pytest            # run from backend/python/
```

Synthetic squat generator + acceptance checks: `tests/` (validates the physics
pipeline recovers realistic velocity/power within the contract's bounds).

## Contract

API surface: `docs/02-backend-api-data-contract.md`. Base `http://<host>:8008/api/v1`.
