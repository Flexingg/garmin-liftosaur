# 00 — Architecture & Agent Orchestration

## 1. Agent roles

| Agent | Focus | Workspace | Owns |
|-------|-------|-----------|------|
| **Lead Agent** | Architecture, data contracts, orchestration, gates | `docs/` | Contracts `01`, `02`; coordinates sub-agents |
| **Embedded Agent** | Monkey C on watch | `embedded/monkeyc` | State machine, UI, sensor listener, BLE transmit |
| **Mobile Agent** | Dart/Flutter on phone | `mobile/flutter` | BLE client, Liftosaur API, buffering, POST |
| **Data/ML Agent** | Python backend | `backend/python` | FastAPI ingestion, kinematic physics, DB, ML rep counting |

Contracts are the source of truth. All three agents code against `01` and `02`; any change
must be made to the contract first, then propagated.

## 2. Garmin watch state machine

```
STATE_INIT ──▶ STATE_IDLE ──▶ STATE_RECORDING ──▶ STATE_STOPPED ──▶ STATE_IDLE
   │              │  ▲              │                   │
   └──────────────┘  └──────────────┴───────────────────┘
            (hardware Start/Stop toggles)
```

- `STATE_INIT` — sensors acquired, BLE/Comms not yet connected. Waiting for `onStart()`.
- `STATE_IDLE` — waiting. Shows current exercise + prescribed weight string from phone (Phase 3).
- `STATE_RECORDING` — `Toybox.ActivityRecording` started; sensor listener active; buffering samples.
- `STATE_STOPPED` — recording stopped; final flush / end-of-set flag sent over BLE.

## 3. ⚠️ Key design decision & risk — the 100 Hz requirement

**The user's plan asks for 100 Hz accelerometer data via `Toybox.Sensor`. This is the single
biggest technical risk in the project and must be confirmed before Phase 1 coding.**

- Garmin's public Connect IQ API (`Toybox.Sensor`) does **not** expose a user-configurable
  sample rate. `Sensor.registerForData` / `SensorData.accel` return data at whatever rate the
  OS buffers it — on Venu 2-class devices the effective accelerometer rate over Toybox is
  typically on the order of **~10–25 Hz**, not 100 Hz.
- True high-rate raw IMU on Garmin requires proprietary SDKs that are not available to
  independent developers, or sampling inside `Sensor` callbacks and stamping your own clock
  (which still doesn't raise the underlying rate).
- **Consequence for the physics (Phase 4):** velocity = ∫a·dt and power = m·a·v degrade badly
  at low sample rates. Squat bar-path can still be recovered, but expect noisier velocity/power.
  This is exactly what Hardware Checkpoint 4 ("are you generating 10,000 watts?") is designed
  to catch.

**Options to confirm with Jonathan:**
1. Proceed with "max available rate" (whatever Toybox gives, stamped with a monotonic ms
   clock) and validate at checkpoint 1. **Recommended** — this is the only consumer-API option.
2. Accept ~25 Hz as the design target and size the payload contract accordingly.
3. Reduce scope: record on the watch and transmit after (batch) instead of streaming, if the
   per-second chunk rate turns out to be the bottleneck.

The contract (doc `01`) is written to carry a `sample_rate_hz` field so the rate is
self-describing regardless of which option is chosen.

## 4. BLE transport options (Phase 2)

Two candidate transports for watch → phone. Decision needed before Phase 2.

| Option | Mechanm | Pros | Cons |
|--------|---------|------|------|
| **A. Garmin Connect IQ BLE (`Toybox.BluetoothLowEnergy`)** | Watch acts as a BLE peripheral; Flutter uses a GATT client (`flutter_blue_plus`) | Direct to custom app, no Garmin Connect dependency, low latency | More GATT plumbing; only one Central at a time |
| **B. `Toybox.Communications.transmit` (HTTP over phone)** | Watch posts via the phone's network through the Garmin app | Simplest to get working | Requires Garmin Connect app; not raw BLE; not real-time streaming |

**DECIDED (2026-09-12): BLE — but the roles are INVERTED.** Real-time BLE won.

Garmin's Connect IQ BLE API is **central role only** (no advertising, no GATT
server), so the watch *cannot* be a BLE peripheral. Instead the **phone** is the
peripheral/GATT server and the **watch** is the central that scans, pairs and
writes chunk frames to it. Both ends are implemented and documented in
`docs/04-ble-transport.md` — read that before touching either side.

## 5. Data flow end-to-end

1. Watch samples accelerometer while `STATE_RECORDING`.
2. Every ~1 s the watch emits a **chunk** (Monkey C → Flutter) with X/Y/Z arrays, seq, timestamp.
3. When the user stops the set, watch sends an **end-of-set** frame with the STOPPED flag.
4. Flutter buffers chunks, concatenates on STOPPED, attaches Liftosaur weight context, POSTs to backend.
5. Backend cleans (low-pass), isolates gravity, integrates for velocity, computes power, runs rep detection, stores, returns result.

## 6. Existing reuse

- **Liftosaur API** — auth + endpoint contract already reverse-engineered in
  `C:/RandallEngineering/RandallReps/liftosaur2sparky/sync.mjs`:
  `https://www.liftosaur.com/api/v1`, `Authorization: Bearer <key>`, `/history?limit=20&cursor=…`.
  Phase 3 will extend this to fetch current program/exercise/prescribed weight.
- **Rep counting** — RandallReps backend is camera/pose-based (`rep_counter.py`), so the
  *concept* carries over but the accelerometer pipeline is new.
