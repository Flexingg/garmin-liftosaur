# Backend workspace (Python — FastAPI physics + rep detection)

Owner: Data/ML Agent.

```bash
cd /c/RandallEngineering/Garmin_Liftosaur/backend/python
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt      # (Windows)
.venv/Scripts/uvicorn app.main:app --reload --port 8000
curl http://127.0.0.1:8000/api/v1/health
```

## Phases

- **Phase 4** — `app/physics/` kinematics: low-pass filter, gravity isolation, integrate
  acceleration → velocity, compute power. Units per contract doc 02 §4.
- **Phase 5** — `app/ml/` rep detection: DB storage, peak detection on Z-axis zero-crossings,
  Random Forest / 1D-CNN classifier.

## Contract

API surface: `docs/02-backend-api-data-contract.md`. Base `http://<host>:8000/api/v1`.
