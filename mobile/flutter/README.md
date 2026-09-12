# Mobile workspace (Flutter — companion phone app)

Owner: Mobile Agent. Talks to the watch (docs/01) and to the Python backend
(docs/02).

## Pipeline

```
watch frames (docs/01)          SetSession                  backend (docs/02)
  HELLO / CHUNK / SET_END  ->   validate, de-gap,     ->    POST /api/v1/sets
  JSON dict form                accumulate samples          physics + rep count
```

| File | Role |
|------|------|
| `lib/protocol.dart` | Decodes the docs/01 frame dictionary into `LiftFrame`; flags protocol/structural problems instead of throwing |
| `lib/set_session.dart` | Assembles chunks into one set; detects seq gaps (dropped frames), duplicates and post-`SET_END` traffic; renders the docs/02 request body |
| `lib/backend_client.dart` | `POST /api/v1/sets`, `GET /api/v1/health`; physics decoding + a plausibility check for the "10,000 W" failure mode |
| `lib/frame_source.dart` | `FrameSource` abstraction + `SyntheticFrameSource` (deterministic squat signal) |
| `lib/main.dart` | UI: backend health, capture stats, upload, physics result |

**No third-party packages.** The HTTP client uses `dart:io` directly, so the app
has zero pub dependencies to keep in sync and every layer below the radio is
runnable on the Dart VM.

## What is NOT wired yet

The watch link itself. `docs/00 §4` still has an open decision — BLE GATT
peripheral (option A) vs `Toybox.Communications.transmit` (option B) — so the
app drives the pipeline from `SyntheticFrameSource`. When the transport is
chosen it is a single `FrameSource` implementation away; nothing else changes.
On the watch side, frames are currently handed to `LiftLogTransport` (console),
which is the same seam.

## Run

```bash
flutter pub get
flutter analyze
flutter test                      # protocol, session, HTTP client, widget tests
```

End-to-end against the real backend:

```bash
# terminal 1
cd ../../backend/python && ./.venv/bin/uvicorn app.main:app --port 8231
# terminal 2
dart run tool/smoke_e2e.dart http://127.0.0.1:8231/api/v1     # prints physics, exits non-zero on failure
```

`smoke_e2e.dart` imports only the pure-Dart layers, so it runs without Flutter
and without a device. It is what caught the Nyquist bug that made the backend
reject every 20 Hz set (see `backend/python/tests/test_nyquist_regression.py`).

Point the UI at the backend with the "Backend base URL" field
(default `http://192.168.1.146:8000/api/v1`).
