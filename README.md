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
- **`docs/04-ble-transport.md`** — ⭐ the real-time BLE link: why the phone is the
  peripheral and the watch is the central, the UUIDs, the binary wire format,
  fragmentation, and what is/isn't verified.

## Download & install (no build required)

Both artifacts are side-loads. Nothing here needs the source tree or a toolchain.

| Artifact | Where | Install |
|---|---|---|
| **Watch app** — `Liftosaur.prg` (signed, Venu 2 / 2S, product `006-B3704-00`) | [`dist/Liftosaur.prg`](dist/Liftosaur.prg) — committed to this repo | Copy into `GARMIN/APPS` over MTP, then **physically unplug the watch** (installing happens on unplug, not software eject). |
| **Phone app** — `app-release.apk` (Android, Flutter) | **[Latest GitHub release](https://github.com/Flexingg/garmin-liftosaur/releases/latest)** | Allow "install unknown apps" for your file manager, then open the APK. |

Verify the watch artifact if you like:
```bash
sha256sum -c dist/Liftosaur.prg.sha256
```

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

## Phone app: release builds need the network permissions declared explicitly

`flutter build apk --release` produces an APK that **cannot reach the backend** unless
you declare these in `mobile/flutter/android/app/src/main/AndroidManifest.xml`:

- `<uses-permission android:name="android.permission.INTERNET" />` — Flutter injects
  INTERNET into the **debug/profile** manifests only, so the release APK has no network
  access at all while debug builds work fine. This is the #1 "the app can't see the
  backend" cause.
- `android:usesCleartextTraffic="true"` on `<application>` — the backend is plain HTTP
  on the LAN and Android 9+ blocks cleartext by default.

Verify what actually shipped (do not trust the source):

```bash
unzip -p build/app/outputs/flutter-apk/app-release.apk AndroidManifest.xml \
  | strings -el | grep -E "permission.INTERNET|usesCleartextTraffic"
```

## Backend service (Hermes box)

The backend runs as a systemd **user** service so it survives logout and reboot:

```bash
systemctl --user status garmin-liftosaur-backend.service     # :8008, bound 0.0.0.0
journalctl --user -u garmin-liftosaur-backend.service -f    # logs
curl http://192.168.1.146:8008/api/v1/health                 # {"status":"ok", ...}
```

Unit: `~/.config/systemd/user/garmin-liftosaur-backend.service`. It binds `0.0.0.0`
on purpose — the phone reaches it over the LAN, and the app's default backend URL is
`http://192.168.1.146:8008/api/v1`.

## Roadmap

- **Phase 0** — architecture + data contracts + scaffolding ✅
- **Phase 1** — Garmin core UI + sensor listener (Monkey C) ✅ **Hardware Checkpoint 1 PASSED 2026-09-12**
  (app installs on the Venu 2S, launches, and its state machine responds to Start/Stop)
- **Phase 2** — data bridge 🚧 *in progress*
  - ✅ watch: contract frames built (`source/LiftFrame.mc`) and emitted on a ~1 Hz
    chunk cadence; `SampleBuffer` drains a bounded pending queue and counts
    drops; transport is a swappable seam (`source/Transport.mc`, currently logs)
  - ✅ phone: frame decoding, set assembly with seq-gap detection and the backend
    request body (`mobile/flutter/lib/`)
  - ✅ **transport decided: BLE, with the roles INVERTED** (docs/04). Connect IQ
    BLE is central-only, so the PHONE advertises a GATT server and the WATCH
    connects as a central and writes chunk fragments to it. Frame codec +
    reassembly are unit-tested with golden vectors; the watch app compiles with
    `source/LiftBleTransport.mc`.
  - ⬜ Hardware Checkpoint 2 — watch pairs with the phone and streams chunks
    without dropped frames (**not yet run on hardware**)
- **Phase 3** — Liftosaur API integration (fetch weight/exercise) 🛑 HW checkpoint 3
- **Phase 4** — Physics engine + backend ingestion ✅ *verified end-to-end*
  (`mobile/flutter/tool/smoke_e2e.dart` → 20 Hz set → peak 278 W / 1.62 m/s).
  Fixed a Nyquist bug that rejected every ~20 Hz set — see
  `backend/python/tests/test_nyquist_regression.py`.
- **Phase 5** — ML rep detection 🛑 HW checkpoint 5

Hardware checkpoints require human action (sideload `.prg`, run the app on the physical
phone/watch) — the phases are gated on those validations.

## Tests

```bash
cd backend/python && ./.venv/bin/python -m pytest -q      # 23 passed
cd mobile/flutter && flutter test                          # 37 passed
cd embedded/monkeyc && ./tools/linux-build.sh venu2s       # BUILD SUCCESSFUL
```

