# Garmin_Liftosaur

A Garmin app (Venu 2 target) that lets you log Liftosaur workouts by wearing your watch
and doing the reps — the watch streams accelerometer data to a companion Flutter phone
app, which forwards the set to a Python backend that does the kinematic physics and
machine-learning rep detection.

```
┌────────────┐   BLE   ┌──────────────┐   HTTPS   ┌──────────────┐
│ Garmin Venu2│ ─────▶ │ Flutter phone │ ───────▶ │ Python backend│
│  Monkey C   │  chunk │   app        │   JSON   │  FastAPI     │
└────────────┘        └──────────────┘           └──────┬───────┘
   100Hz IMU             Liftosaur API                   Physics + ML
                                                         rep counting
```

## Three workspaces

| Workspace | Path                          | Language | Primary agent      |
|-----------|-------------------------------|----------|--------------------|
| Embedded  | `embedded/monkeyc`            | Monkey C | Embedded Agent     |
| Mobile    | `mobile/flutter`              | Dart     | Mobile Agent       |
| Backend   | `backend/python`              | Python   | Data/ML Agent      |

## Documentation

- `docs/00-architecture-and-orchestration.md` — agents, state machine, key design decisions & risks
- `docs/01-ble-payload-data-contract.md` — Monkey C → Flutter payload (Task 0.1)
- `docs/02-backend-api-data-contract.md` — Flutter → Python API (Task 0.2)

## Roadmap

- **Phase 0** — architecture + data contracts + scaffolding ✅ (in progress)
- **Phase 1** — Garmin core UI + sensor listener (Monkey C) 🛑 HW checkpoint 1
- **Phase 2** — BLE data bridge (Flutter + Monkey C transmit) 🛑 HW checkpoint 2
- **Phase 3** — Liftosaur API integration (fetch weight/exercise) 🛑 HW checkpoint 3
- **Phase 4** — Physics engine + backend ingestion 🛑 HW checkpoint 4
- **Phase 5** — ML rep detection 🛑 HW checkpoint 5

Hardware checkpoints require human action (sideload `.prg`, run the app on the physical
phone/watch) — the phases are gated on those validations.
