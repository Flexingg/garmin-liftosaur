# Garmin_Liftosaur

A Garmin app (Venu 2S target) that lets you log Liftosaur workouts by wearing your
watch and doing the reps — the watch streams accelerometer data to a companion
Flutter phone app, which forwards the set to a Python backend that does the
kinematic physics and machine-learning rep detection.

```
┌────────────┐   BLE   ┌──────────────┐   HTTPS   ┌──────────────┐
│Garmin Venu2S│ ─────▶ │ Flutter phone │ ───────▶ │ Python backend│
│  Monkey C   │  chunk │   app        │   JSON   │  FastAPI     │
└────────────┘        └──────────────┘           └──────┬───────┘
   ~20 Hz IMU            Liftosaur API                  Physics + ML
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
- **`docs/03-garmin-toolchain-and-sideload.md`** — ⭐ verified Connect IQ toolchain,
  signing keys, building, sideloading, failure diagnosis, and how to start a **new**
  Garmin app. Read this before touching the watch.

## Watch app: build & install (verified on hardware)

```bash
cd embedded/monkeyc
./tools/linux-build.sh venu2s      # enforces the 4096-bit key rule, asserts target device
# copy bin/Liftosaur.prg into GARMIN/APPS over MTP, then PHYSICALLY UNPLUG the watch
```

Two things that cost real time and are now enforced/documented:

- **The signing key must be RSA ≥ 4096 bit.** A 2048-bit key builds and signs
  correctly but the watch rejects the install with a misleading
  `Signature check failed`. See `docs/03` §4.
- **Installing happens on physical unplug**, not on software eject. A `.prg`
  still visible in `GARMIN/APPS` means it is not installed yet.

## Roadmap

- **Phase 0** — architecture + data contracts + scaffolding ✅
- **Phase 1** — Garmin core UI + sensor listener (Monkey C) ✅ **Hardware Checkpoint 1 PASSED 2026-09-12**
  (app installs on the Venu 2S, launches, and its state machine responds to Start/Stop)
- **Phase 2** — BLE data bridge (Flutter + Monkey C transmit) 🛑 HW checkpoint 2
- **Phase 3** — Liftosaur API integration (fetch weight/exercise) 🛑 HW checkpoint 3
- **Phase 4** — Physics engine + backend ingestion 🛑 HW checkpoint 4
- **Phase 5** — ML rep detection 🛑 HW checkpoint 5

Hardware checkpoints require human action (sideload `.prg`, run the app on the physical
phone/watch) — the phases are gated on those validations.
