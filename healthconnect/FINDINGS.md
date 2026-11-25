# Findings: what makes a Garmin activity "authentic"

Research date 2026-11-25. Source material: four "Export Original" ZIPs from Garmin
Connect (2 strength, 2 walks, all 24 Nov 2026, all recorded on the same Venu 2S),
the official Garmin FIT SDK profile 21.x, AOSP Health Connect source, and the
androidx Health Connect reference. Raw files are **not** committed (they contain
GPS, body metrics and the watch's unit ID, and this repo is public).

## 1. There is no signature. Identity is a handful of fields.

A FIT file has no cryptographic signature. Its only integrity check is a CRC-16 over
the header and the data, and anyone can recompute it. What Garmin Connect uses to say
"recorded on Venu 2S" is plain data:

| Where | Field | Value in all 4 files |
|---|---|---|
| `file_id` (mesg 0) | `manufacturer` (1) | 1 = garmin |
| | `product` (2) | 3704 = venu2s |
| | `serial_number` (3) | the watch's **Unit ID** (10 digits; redacted here, read from your template at build time) |
| | `time_created` (4) | the activity start time |
| | `type` (0) | 4 = activity |
| | field 7 (undocumented) | present but invalid |
| `file_creator` (49) | `software_version` | 1905 = firmware 19.05 |
| `device_info` (23), `device_index`=0 (creator) | manufacturer / product / serial / software_version, `source_type`=5 (local) | same as above |
| `device_info` index 1..6 | barometer, gps (product 3799 fw 6.60), accelerometer, whr (wrist HR, fw 0.06), sensor hub (product 3707 fw 27.16) | written at start **and** again at stop |
| header | protocol 0x10 (2.0), profile 21115, 14-byte header | |

Garmin Connect checks the device on the server side. Fit-File-Faker, a maintained tool
that rewrites third-party FITs so they unlock Training Effect, Training Status and
challenges, warns that the serial must be a real **Unit ID** that matches the product,
not a random number. We sidestep that problem: we copy the identity from a file your
watch really wrote.

So "signing as my watch" means: copy `file_id`, `file_creator` and the `device_info`
block from a real file, then recompute the CRC. `build_fit.py` does that.

## 2. A real file's full fingerprint, beyond identity

If anything looks for synthetic files, it looks at structure, so we mirror it.
`tools/fit_fingerprint.py FILE` prints all of this, and `--diff REAL CANDIDATE`
compares two files.

**Message order on the Venu 2S (all four files):**
```
file_id, file_creator, 288, 327x2, 326, event(timer start), device_info x5-7, 22, 141,
device_settings, user_profile, 79, sport, training_settings, zones_target,
  [ record (+gps_metadata on GPS sports) + 233 ] x N   with set/time_in_zone (strength)
                                                       or lap/time_in_zone (walk) inline,
event(timer stop_all), device_info x5-7, [remaining sets], 140, session, time_in_zone, activity
```

**Undocumented messages** (not in the public FIT profile). What they seem to be:

| mesg | count | best guess | what we do |
|---|---|---|---|
| 22 | 1-15 | sensor/"device used" state | copied from template preamble only |
| 79 | 1 | user metrics snapshot (VO2max/HR-METS inputs) | copied from template |
| 140 | 1, just before session | **on-device Firstbeat results** (Training Effect, load, recovery) | **not written** (see §5) |
| 141 | 1 | GPS ephemeris/EPO status | copied |
| 233 | 1 per record | opaque 4-byte blob per second | not written (raw sensor-derived, unknown) |
| 288 / 325 / 326 / 327 / 329 | various | periodic sensor/stress/state snapshots; 329 is a lat/long pair | preamble copies only |

**Undocumented record fields** (strength files; also some walk records):
- `136`: always identical to `heart_rate` (wrist HR copy). We write it equal to HR.
- `143`: flat or slowly falling (24→22, 47→44, 67), so almost certainly **Body Battery**. We write invalid.
- `135`: 0-176, moves with exertion. Unknown. We write invalid.
- `134`: always invalid in these files. We write invalid.

Writing the *invalid* sentinel keeps the exact same record layout without inventing
values.

**Strength `set` (225) conventions on the watch:**
- Active and rest sets alternate. `set_type` is 1 = active, 0 = rest.
- An active set's `timestamp` is the moment the *following rest* ends, not when the set ends.
- `category` is a 2-element array (top 2 auto-detection guesses, e.g. `[push_up, triceps_extension]`).
- Undocumented field `2` (uint8z[2]) holds what look like confidence scores (229, 153, 255...).
- **`weight` is never set** in your files, and reps are auto-counted (two curl sets got 0 and 1 reps).
  Liftosaur data would be *better* than the watch here.
- Each set is followed by a `time_in_zone` with `reference_mesg` = 216 (sic) and `reference_index` = set index.
- The last two sets are written after the timer stops.
- `session.num_laps` = number of set messages. Strength files contain **no `lap` messages**.
  Undocumented `session.151` = number of active sets, and `session.78` = active time (sum of active set durations).

**Walk conventions:**
- 1 Hz records. Auto-lap every 1 mile (`lap_trigger`=2), manual laps (0), and a final lap (7 = session_end).
- Cadence is in strides/min; `total_cycles` = `total_strides` = steps / 2.
- Each record has a `gps_metadata` (160) twin carrying enhanced altitude and speed.

**Session/sport:** `sport` 10/20 is "Strength" and 11/0 is "Walk". The profile name is
also stored as `session.110`. `activity.local_timestamp` minus `timestamp` gives the
local UTC offset (-18000 s in these files).

## 3. Things worth knowing about your data

- **Neither walk recorded heart rate.** On 25184015830 only 7 of 3928 records have HR.
  On 25189779984 it is 2 of 3896, and session avg/max are 72/72. The watch switched to
  a record layout without HR. This happened on both walks, so it is probably not a
  one-off loose strap. Whatever the cause, your Wear OS HR would fill a real gap here.
- **Walk 25189779984 has `power_down`/`power_up` events mid-activity.** Elapsed time
  is 10159 s but the timer ran only 3835 s, and the records span 10978 s. The watch
  rebooted or died during the walk.
- The strength sessions used auto rep counting and had no weights entered (see above).

## 4. Health Connect side (verified against AOSP source)

A Health Connect export ("Health Connect.zip") contains one SQLite DB, which is a copy
of the provider's own database. Google does not document the schema. The names below
come from the AOSP sources at
`packages/modules/HealthFitness/service/java/.../storage/datatypehelpers/*Helper.java` (read 2026-11-25):

| table | key columns |
|---|---|
| `exercise_session_record_table` | `row_id`, `uuid`, `start_time`, `end_time` (epoch ms), `start_zone_offset` (s), `exercise_type`, `title`, `notes`, `has_route`, `app_info_id`, `device_info_id` |
| `exercise_segments_table` | `parent_key`→session.row_id, `segment_start_time`, `segment_end_time`, `segment_type`, `repetitions_count` |
| `exercise_laps_table` | `parent_key`, `lap_start_time`, `lap_end_time`, `lap_length` (m) |
| `exercise_route_table` | `parent_key`, `timestamp_millis`, `latitude`, `longitude`, `altitude`, `horizontal_accuracy`, `vertical_accuracy` |
| `heart_rate_record_table` + `heart_rate_record_series_table` | series: `parent_key`, `epoch_millis`, `beats_per_minute` |
| `steps_record_table` | `start_time`, `end_time`, `count` |
| `distance_record_table` | `distance` (m) |
| `total_calories_burned_record_table`, `active_calories_burned_record_table` | `energy` in **small calories** (AOSP rebuilds the record with `Energy.fromCalories(getEnergy())`) → ÷1000 for kcal |
| `application_info_table` | `row_id`, `package_name` |
| `device_info_table` | `manufacturer`, `model`, `device_type` |

Constants (developer.android.com): exercise types WALKING 79, RUNNING 56, STRENGTH_TRAINING 70,
WEIGHTLIFTING 81, HIKING 37, BIKING 8 and others (see `tools/mappings.py`). Segment types
run 0-67 (BENCH_PRESS 5, DEADLIFT 11, SQUAT 51, PAUSE 39, REST 44...). Health Connect has
**no weight-per-set field**, so weights have to come from Liftosaur.

**Loop hazard:** Garmin Connect writes *into* Health Connect too. The reader drops
anything from `com.garmin.android.apps.connectmobile` by default. Without that, you would
re-import Garmin's own data as a new Garmin activity.

## 5. What the server will and won't do (expected; still needs a live test)

| Feature | Expectation | Why |
|---|---|---|
| Shows as "Venu 2S" | yes | identity copied from your real file |
| HR graph, zones, calories, distance, map, sets/reps/weight | yes | standard messages, layouts identical to the watch |
| Training Effect / load / Training Status | **probably yes** | Fit-File-Faker's whole premise is that the server computes TE when a valid Garmin device + Unit ID is present; mesg 140 is not required. **Unverified for Venu 2S.** |
| Body Battery, stress, all-day HR, daily steps | no | these come from the watch's wellness/monitoring files, not activity files |
| Duplicates | rejected (409) | Garmin rejects a file with the same start time as an existing activity; `upload.py` also checks for overlaps |

## 6. Round-trip validation (done in this session)

Each real FIT was turned into session JSON (`fit_to_session.py`), rebuilt with the
*other* file of the same kind as the template (`build_fit.py`), then decoded with
the official `garmin-fit-sdk` (integrity OK, 0 errors) and with `fitparse`:

| | real | synthesized |
|---|---|---|
| strength 25187432083: elapsed / avg HR / max HR / reps / sets / active time / kcal | 3771.9 s / 86 / 138 / 45 / 12 / 390.3 s / 225 | 3772 s / 86 / 138 / 45 / 12 / 390.3 s / 225 |
| walk 25184015830: distance / timer / ascent / descent / steps (strides) / avg cad | 3903 m / 3927 s / 41 / 39 / 2700 / 41 | 3982 m / 3927 s / 40 / 39 / 2699 / 41 |

Distance is 2% high because we integrate raw GPS, while the watch smooths its fused
distance. `fit_fingerprint.py --diff` reports the only structural differences as the
deliberately omitted 140/233/325 messages and record fields 134/135/143 on one walk
layout.

The same pipeline was run end to end against a **mock** Health Connect DB built with the
AOSP column names (`hc_export_reader.py` → `build_fit.py`): 2 sessions, Garmin-origin
decoy HR correctly ignored.

**Not yet done:** a real Health Connect export, and an actual upload to Garmin Connect.
