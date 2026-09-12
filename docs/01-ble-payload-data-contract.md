# 01 — BLE Payload Data Contract (Monkey C → Flutter)

**Owner:** Lead Agent (source of truth) · **Consumers:** Embedded Agent (producer), Mobile Agent (consumer)
**Status:** v1.0 · Phase 0 / Task 0.1

## 1. Frame types

| `type` | Name       | Direction           | Purpose                                   |
|--------|------------|---------------------|-------------------------------------------|
| `0`    | HELLO      | Watch → Phone       | Announces capability + config on connect  |
| `1`    | CHUNK      | Watch → Phone       | ~1 s of accelerometer samples (streaming) |
| `2`    | SET_END    | Watch → Phone       | Set stopped — final flush, STOPPED flag   |
| `3`    | CMD        | Phone → Watch       | Set exercise/weight text (Phase 3)        |

Every frame carries the common header, then a type-specific body.

> **Transport note (2026-09-12):** the BLE link is implemented with the roles
> *inverted* — the **phone** is the BLE peripheral (GATT server) and the **watch**
> is the central, because Connect IQ exposes BLE only in the central role. Over
> BLE the **binary** form below (§2, §3) is used; the JSON/dict form (§7) is for
> the `Toybox.Communications` path. Fragmentation and the exact byte layout are in
> `docs/04-ble-transport.md`.

## 2. Common header (binary, 24 bytes)

| Offset | Size | Field            | Type        | Notes                                        |
|--------|------|------------------|-------------|----------------------------------------------|
| 0      | 2    | magic            | uint16      | `0x4C46` = "LF"                              |
| 1→     | 1    | version          | uint8       | `1`                                          |
| 3      | 1    | type             | uint8       | frame type (0–3)                             |
| 4      | 4    | seq              | uint32      | monotonic per-watch frame counter            |
| 8      | 8    | timestamp_ms     | int64       | epoch ms at frame creation                   |
| 16     | 2    | exercise_id      | uint16      | stable app-local id (0 = unset)              |
| 18     | 1    | rate_hz          | uint8       | actual sample rate of the source (see §4)    |
| 19     | 1    | flags            | uint8       | bit0=CHUNK_END (STOPPED), bit1=gravity_known |
| 20     | 4    | reserved         | uint32      | 0                                          |

## 3. CHUNK body (type 1)

Immediately follows the 24-byte header. Compact fixed-point, tightly packed.

| Field            | Type   | Size/Format                      | Notes                            |
|------------------|--------|----------------------------------|----------------------------------|
| sample_count     | uint16 | 2 B                              | samples in this chunk (≈ rate_hz) |
| channel_mask     | uint8  | 1 B                              | bit0=X, bit1=Y, bit2=Z            |
| scale            | int16  | 2 B                              | divide raw int16 samples by this for m/s² |
| samples          | int16  | `sample_count × popcount(mask)` × 2 B | X,Y,Z interleaved per sample     |

Example: 100 samples × 3 channels = 100 × 3 × 2 = **600 B** body (with X/Y/Z each int16).
At 25 Hz: 25 × 3 × 2 = **150 B** body.

Wire format for one channel sample `s` → `accel_m_s2 = s / scale`. `scale=1000` → 1 mm/s²
resolution (±32.7 m/s² full range), `scale=100` → 1 cm/s² resolution.

## 4. Sample-rate encoding (self-describing)

The watch stamps `rate_hz` with the **actual** rate it is getting from `Toybox.Sensor`
(normalized to nearest int). Consumers MUST NOT assume 100 Hz — treat `rate_hz` as ground
truth. `timestamp_ms` on each frame marks the first sample; sample `k` occurred at
`timestamp_ms + (k * 1000 / rate_hz)`.

## 5. SET_END body (type 2)

| Field      | Type    | Size | Notes                       |
|------------|---------|------|-----------------------------|
| duration_ms| uint32  | 4 B  | total recorded time         |
| rep_hint   | uint8   | 1 B  | manual rep count if user taps (0 = auto) |

`flags.bit0` (CHUNK_END) must be set. After SET_END the watch returns to STATE_IDLE.

## 6. CMD body (type 3, Phone → Watch)

| Field        | Type   | Size         | Notes                          |
|--------------|--------|--------------|--------------------------------|
| text_len     | uint8  | 1 B          | byte length of `text`          |
| text         | ASCII  | text_len B   | e.g. `"Squat - 225 lbs"`       |

Watch renders `text` in the STATE_IDLE UI.

## 7. JSON / dictionary form (for Toybox.Communications path)

When transported as a JSON dict (option B in doc 00), the same frame maps to:

```json
{
  "v": 1,
  "type": "chunk",
  "seq": 412,
  "ts": 1724865600123,
  "exercise_id": 3,
  "rate_hz": 25,
  "flags": 0,
  "sample_count": 25,
  "channels": ["x","y","z"],
  "scale": 1000,
  "samples": [[-120, 980, -44], [0, 1010, -60]]
}
```

`SET_END` → `{"v":1,"type":"set_end","seq":413,"ts":...,"duration_ms":18000,"rep_hint":0}`
`CMD`    → `{"v":1,"type":"cmd","text":"Squat - 225 lbs"}`

## 8. Validation / acceptance

- A CHUNK with `sample_count == rate_hz` = 1 full second of data.
- `seq` contiguous across chunks; gap detection = dropped packet (checkpoint 2 criterion).
- X/Y/Z are acceleration in **m/s²** (gravity ≈ +9.81 on Z when wrist is still) after `scale`.
