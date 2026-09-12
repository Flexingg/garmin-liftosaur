# 04 — BLE transport (phone = peripheral, watch = central)

**Status:** implemented on both sides; the wire codec is unit-tested and the watch
app compiles for `venu2s`, but **end-to-end BLE has not been verified on hardware
yet**. That is Hardware Checkpoint 2. Where something is unverified it is marked.

---

## 1. ⚠️ The roles are inverted — and they have to be

**A Garmin Connect IQ app cannot be a BLE peripheral.** The `Toybox.BluetoothLowEnergy`
module documentation states it plainly:

> The BluetoothLowEnergy module provides access to Generic BLE communication
> functionality in **the central role**. Including the ability to scan for
> peripheral devices, pair with sensors, and performing GATTC operations on a
> peripheral.

Every `BleDelegate` callback is central-side (`onScanResults`, `onCharacteristicChanged`
— i.e. notifications *received from* a peripheral). There is no advertising API and
no GATT-server API. So "true BLE real-time streaming" is only achievable by
inverting who does what:

```
┌──────────────────────────────┐            ┌───────────────────────────────┐
│ PHONE (Flutter)              │            │ WATCH (Monkey C)              │
│   PERIPHERAL / GATT server   │◀───BLE────▶│   CENTRAL                     │
│   advertises the service     │  writes    │   scans, pairs, writes chunks │
│   receives writes on RX char │            │   LiftBleTransport            │
└──────────────────────────────┘            └───────────────────────────────┘
```

The watch scans for the phone, pairs with it, resolves the characteristic, and
writes CHUNK frames to it. Latency is a BLE connection interval (7.5–30 ms), which
is what makes this real-time.

**Alternatives considered and rejected:**

| Option | Why not |
|---|---|
| `Toybox.Communications.makeWebRequest` / `transmit` | Goes through Garmin Connect Mobile; not BLE, seconds of latency, and no live streaming |
| `GenericChannel` | It is `Toybox.**Ant**.GenericChannel` — ANT, not BLE. Needs an ANT radio on the phone |
| Watch as peripheral | **Not exposed by the Connect IQ API at all** (see above) |

## 2. UUIDs — the contract between the two sides

| Role | UUID | Where |
|---|---|---|
| Service | `4c494654-0001-4000-8000-00805f9b34fb` | `LiftBle.serviceUuid()` / `kLiftServiceUuid` |
| Data (watch → phone) | `4c494654-0002-4000-8000-00805f9b34fb` | `LiftBle.dataUuid()` / `kLiftDataUuid` |

The phone advertises the service and serves the data characteristic as its **RX**
characteristic (`GattServerSettings.rxCharacteristicUuid`), which is what
`FlutterBlePeripheral.onDataReceived` reports. Local name advertised: `Liftosaur`.

These strings exist in exactly two places — `embedded/monkeyc/source/LiftBleTransport.mc`
and `mobile/flutter/lib/ble_link.dart` — and a test asserts the Dart side, so a
change on one side breaks a test instead of silently failing to connect.

## 3. Wire format

BLE uses the **binary** frame form (docs/01 §2–§3), not the JSON dict form: a
one-second CHUNK at 20 Hz is `24 + 20*3*2 = 144` bytes binary versus ~400 bytes of
JSON.

**Frame header (24 B, little-endian)** — docs/01 §2:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic `0x4C46` ("LF") — bytes `46 4c` |
| 2 | 1 | protocol version = 1 |
| 3 | 1 | type: 0 HELLO, 1 CHUNK, 2 SET_END, 3 CMD |
| 4 | 4 | seq (uint32) |
| 8 | 8 | timestamp_ms (int64) |
| 16 | 2 | exercise_id (uint16) |
| 18 | 1 | rate_hz |
| 19 | 1 | flags (bit0 CHUNK_END, bit1 GRAVITY_KNOWN) |
| 20 | 4 | reserved |

**CHUNK body:** `sample_count` u16, `channel_mask` u8, `scale` i16, then
`sample_count × popcount(mask)` i16 values, X/Y/Z interleaved.
**SET_END body:** `duration_ms` u32, `rep_hint` u8.

### Fragmentation

A GATTC write cannot carry an arbitrary payload, so every write is prefixed with a
4-byte fragment header:

```
u16 totalFrameLength (LE) | u8 fragmentIndex | u8 fragmentCount | payload...
```

The receiver accumulates fragments by index and yields the frame when complete.
Default payload is **180 bytes** (`MAX_FRAGMENT_PAYLOAD` in the watch transport), so
the required MTU is `4 + 180 + 3 = 187`. If writes start failing on hardware, lower
this first — it is the single tuning knob. The phone logs the negotiated MTU so you
can see what the link actually agreed to.

Fragments use `WRITE_TYPE_DEFAULT` (no per-write response) so streaming is not
throttled by a round trip per fragment; ordering is what makes reassembly valid.

### The layout is pinned by tests

`mobile/flutter/test/binary_frames_test.dart` contains **golden vectors computed
independently from this spec**, not from the encoder — so an accidental change to
the byte layout fails a test rather than corrupting sets in the field. The Monkey C
encoder (`source/LiftBinary.mc`) mirrors the same offsets; it is compile-verified
but not (yet) cross-checked against the Dart decoder on real hardware.

## 4. Sequence of events

**Phone:** start the app → `Start BLE link` → advertises + serves the GATT service.
The screen shows `ble:advertising`, the negotiated MTU and fragment/frame counters.

**Watch:** app start → `LiftBleTransport.start()`:

```
setDelegate → setConnectionStrategy → registerProfile({service, [dataChar]})
  → setScanState(SCAN_STATE_SCANNING)
  → onScanResults → setScanState(OFF) → pairDevice(scanResult)
  → onConnectedStateChanged(CONNECTED) → device.getService() → service.getCharacteristic()
  → requestWrite(fragment, {WRITE_TYPE_DEFAULT}) per fragment
```

On disconnect it drops back to scanning, so the next set reconnects. The watch UI
shows the transport state (`ble` / `ble:scan` / `ble:idle`), frames sent, dropped
samples and write failures — the drop/fail counters turn orange when non-zero.

Frames are emitted by a **tee transport** (`LiftTeeTransport`), so every frame is
also written to the device console. That log is the only observability available on
a physical watch, and it is what makes Hardware Checkpoint 2 checkable even if the
BLE link misbehaves.

## 5. Pairing / bonding caveat  *(unverified)*

The connection strategy is left at the platform default (non-secure, so the RX
characteristic is open and no bonding prompt is expected).

**`setConnectionStrategy` is NOT callable on the Venu 2S.** It appears in the SDK
9.2.0 API reference, but the watch's runtime (firmware 19.05 / **CIQ 6.0.2**) does
not expose it, and Monkey C compiles the call anyway. The failure is a runtime
crash on app start:

```
Error: Symbol Not Found Error
Details: "Could not find symbol 'setConnectionStrategy'"
Filename: Liftosaur / Appname: Liftosaur
  LiftBleTransport.mc line 124, start
```

So there is no way to opt into `CONNECTION_STRATEGY_SECURE_PAIR_BOND` on this
device — if a securing requirement ever appears, it has to come from the
characteristic's own permissions instead. Verify any candidate API against the
device's own file (`~/.Garmin/ConnectIQ/Devices/<device>/<device>.api.debug.xml`)
or, better, let `tools/check-device-api.py` do it (it now runs as part of the build).

Also confirm the phone is not already at its limit of BLE peripheral connections —
the watch keeps its normal link to Garmin Connect Mobile at the same time, and a
phone peripheral cannot always serve both.

## 5b. Diagnosing a link that sends nothing  *(this is the current state)*

Symptom seen on hardware: the watch paired (a 6-digit passkey appeared), the watch
screen showed `sent=0`, `fail=0`, and the phone received nothing — with **no error
in `CIQ_LOG.YML` at all**.

Two reasons that was a dead end, both now fixed:

1. **`System.println` never reaches `CIQ_LOG.YML`.** That file only records crashes.
   Every `System.println("LiftBle: ...")` we wrote is invisible on a physical watch
   unless the Connect IQ developer console is attached. Do not rely on it for field
   diagnosis.
2. **`emit()` returned silently** when the link was not ready, so a "connected but
   the characteristic was never resolved" state looked identical to "not connected":
   nothing sent, nothing counted.

What to look at now, in order:

- **The watch screen** names the link state directly:
  `off` → `scan` → `paired` → `no-svc` → `no-char` → `ready`, plus
  `snt=` / `skip=` / `fail=`.
  `no-svc` or `no-char` with `skip` climbing pinpoints it exactly: the watch
  connected but could not resolve our service/characteristic on the phone.
  Resolution is also **retried** on every frame, so a slow GATT discovery recovers
  by itself rather than needing a reconnect.
- **The phone's Debug tab** logs everything it observes (advertising state, MTU,
  fragment/frame/decode counters, each frame) and can drive the link by hand
  (`Start advertising`, `Stop`, `Inject test frame`, `Clear`). `Inject test frame`
  pushes a synthetic frame through the identical decode → chart → session → upload
  path, so everything downstream of the radio can be verified with no watch.
- **Independent check, no app involved:** install **nRF Connect** and scan. You
  should see the advertised name `Liftosaur` with service `4c494654-0001-…` and,
  after connecting, a characteristic `4c494654-0002-…`. If you instead see the
  Nordic UART UUIDs (`6e400001-…`), then `flutter_ble_peripheral` did not apply the
  custom `GattServerSettings` and the watch is looking for a service that is not
  being served — which would explain everything.

`GET /health` returning 404 in the backend log is a related trap: a base URL
without `/api/v1` silently produced requests to `/health` and `/sets`. The app now
normalises whatever you type (`BackendClient.normalizeBase`).

## 6. Android permissions

`android/app/src/main/AndroidManifest.xml` declares `BLUETOOTH_ADVERTISE`,
`BLUETOOTH_SCAN` (`neverForLocation`) and `BLUETOOTH_CONNECT` (plus the legacy
pre-API-31 entries). `BLUETOOTH_ADVERTISE` is the one that makes the phone a
peripheral rather than a scanner; without it `start()` reports a denied state
instead of advertising.

## 7. Running it

```bash
# phone (Android; BLE peripheral is not available in the Flutter desktop/test VM)
cd mobile/flutter && flutter run          # then tap "Start BLE link"
# watch
cd embedded/monkeyc && ./tools/linux-build.sh venu2s   # sideload per docs/03
```

Unit tests (no hardware, no Bluetooth): `cd mobile/flutter && flutter test`.

## 8. What is verified, and what is not

| Claim | Status |
|---|---|
| Watch cannot be a BLE peripheral (CIQ is central-only) | ✅ verified against the SDK module docs + BleDelegate API |
| Binary frame layout + golden vectors | ✅ unit-tested (Dart), independently computed |
| Fragment reassembly, duplicates, partial frames, corrupt frames | ✅ unit-tested (Dart) |
| Watch app compiles with BLE transport for `venu2s` | ✅ BUILD SUCCESSFUL, target `006-B3704-00` |
| Flutter app advertises + serves GATT, decodes frames | ⚠️ compiles, analyze clean, decode path unit-tested — **not run on a phone yet** |
| Watch scans → pairs → writes to the phone | ⛔ **not verified on hardware** — Hardware Checkpoint 2 |
| Fragment size 180 / MTU 187 sufficient in practice | ⛔ unverified; first thing to tune |
| `epochMs()` correctness (32-bit overflow fix) | ⚠️ fixed and compiles; confirm timestamps look sane on the phone |
