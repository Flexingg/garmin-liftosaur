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
| `lib/binary_frames.dart` | Compact binary frame codec (docs/01 §2–3) + BLE fragmenter/reassembler |
| `lib/ble_link.dart` | **The real-time BLE link.** This phone is the *peripheral*: it advertises a GATT server the watch writes chunks to |
| `lib/main.dart` | UI: backend health, capture stats, upload, physics result |

**One dependency:** `flutter_ble_peripheral`, and only for the BLE link. The
backend client uses `dart:io` directly, so everything except the radio runs on the
plain Dart VM and is unit-tested without a device.

## The BLE link (roles are inverted)

`docs/04-ble-transport.md` has the full story. The short version: Garmin's Connect
IQ BLE API is **central-role only**, so a watch app cannot be a peripheral. This
app therefore acts as the **peripheral / GATT server** and the watch connects as
the central and writes chunk fragments to us.

Tap **Start BLE link**, then run the watch app and press Start. The status line
reports link state, negotiated MTU and fragment/frame counters so you can see
exactly where a problem is.

Frame decode + reassembly (`binary_frames.dart`, `ble_link.dart`) are pure Dart and
covered by unit tests, including golden byte vectors and corrupt/partial/duplicate
fragments.

`SyntheticFrameSource` remains for developing without hardware, and drives the exact
same session/upload path.

## Run

```bash
flutter pub get
flutter analyze
flutter test                      # protocol, session, HTTP client, widget tests
```

End-to-end against the real backend:

```bash
# terminal 1
cd ../../backend/python && ./.venv/bin/uvicorn app.main:app --port 8008
# terminal 2
dart run tool/smoke_e2e.dart http://127.0.0.1:8008/api/v1     # prints physics, exits non-zero on failure
```

`smoke_e2e.dart` imports only the pure-Dart layers, so it runs without Flutter
and without a device. It is what caught the Nyquist bug that made the backend
reject every 20 Hz set (see `backend/python/tests/test_nyquist_regression.py`).

Point the UI at the backend with the "Backend base URL" field
(default `http://192.168.1.146:8008/api/v1`).
