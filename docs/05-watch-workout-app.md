# 05 — Watch workout app (standalone)

**Status:** builds and is staged for the watch; not yet exercised on hardware.

## What this is

The watch is a **standalone gym companion**: it shows the user's Liftosaur
program and logs the workout, with no BLE and no network during training.

This replaced the BLE streaming design (docs/04) after four hardware cycles
failed to get data off the watch. That work is parked, not deleted: the
accelerometer/BLE path (`RecordingController`, `SampleBuffer`, `LiftTransport`,
`LiftBleTransport`) still compiles but is no longer wired into `app.mc`.

## Why the plan is baked in, not fetched

The watch *can* make HTTP requests (`Communications.makeWebRequest` exists on
the Venu 2S), but the platform returns **`SECURE_CONNECTION_REQUIRED` (-1001)
for a non-https URL**. Our backend is plain HTTP on the LAN, so the watch cannot
talk to it without a real certificate. Baking the plan into the build avoids
that entirely and has the side benefit that the watch cannot fail to load a
workout in a basement gym.

Sync-back (logging sets to Liftosaur) will need an https endpoint. When it
happens, `POST` is already available and `HTTP_REQUEST_METHOD_POST` is present
on this device.

## Data flow

```
Liftosaur API (MCP)                tools/plan_from_liftosaur.py           watch app
  get_program(current)  ──────┐
  list_exercise_data (rm1) ───┴──► parse + compute weights ──► source/PlanData.mc
                                                              dist/plan.json
                                                                   │
                                                       WorkoutController reads LiftPlan
```

Regenerate after the program changes, then rebuild:

```bash
cd embedded/monkeyc
python3 tools/plan_from_liftosaur.py     # pulls the current program + training maxes
HOME=/home/hermes ./tools/linux-build.sh venu2s
```

The key comes from `LIFTOSAUR_API_KEY`, falling back to the key in
`~/.hermes/config.yaml` (the same one the Liftosaur MCP uses).

## How weights are computed

The program is written in Liftoscript with percentages:

```
main / 1x5 65%, 1x5 75%, 1x5+ 85%, 5x10 50% / 180s
Squat[1-4] / ...main / progress: custom(increment: 10lb)
```

`rm1` for the exercise comes from `list_exercise_data`, and each percentage is
multiplied by it and rounded to the nearest 5 lb. AMRAP sets (`5+`) are marked
so the watch shows `x 5+`. Explicit accessory weights (`3x8 / 135lb`) are used
as-is. For the current program, Squat with rm1 335 gives 220 / 250 / **285+**,
then 5x10 at 170 — the four classic 5/3/1 waves.

### Liftoscript subset understood

Deliberately small, and anything unresolved is **reported, never guessed**:

- `# Week N` sections. A named set block is scoped to its **section**: `main`
  is defined under Day 1 and reused by Days 2–4 of the same section, while the
  deload section defines its own `main`. Getting this wrong produced plausible
  but wrong weights (40/50/60% instead of 65/75/85%).
- `## Day NAME` day sections.
- `name / 1x5 65%, ... / 180s` — a named block.
- `Exercise[, Equipment] / 3x8 / 135lb 90s` — inline sets.
- `Exercise / ...block` — reuse a block; `...Other[1]` reuses that exercise's
  own inline definition.

**Not** executed: `progress:` scripts. The watch shows the programmed weight for
a session; it does not apply progression or deload logic. Advancing the program
still happens in Liftosaur.

## Screens and controls

**Day picker** — `up/down` changes day, `select` starts the workout.
The picker lists the program's main section (7 days); the deload days are
parsed and present in the plan but not offered yet.

**Set screen** — shows day + progress, exercise, target `weight x reps`, set
number and rest, and elapsed time.

| Button | Action |
|---|---|
| `select` | complete the set (logs it, starts the rest countdown), or finish when done |
| `up` / `down` | adjust the current set's weight by 5 lb |
| `back` | leave; the save/discard prompt handles the activity |

Rest takes over the full screen as a countdown and vibrates at zero.
On finishing, the activity is stopped and the app asks **"Save workout?"** — so
debugging no longer litters Garmin Connect with throwaway activities. It is
recorded as a **strength training** workout (`SPORT_TRAINING` +
`SUB_SPORT_STRENGTH_TRAINING`; note `SPORT_STRENGTH_TRAINING` does not exist on
this device).

## End-of-workout summary and exit paths (2026-09-18)

Before this date, the cursor running past the last exercise made `currentExerciseName()`
return the literal string `"done"`, which the info/history/stats screens then
rendered as a title — and even fetched from the backend
(`GET /api/v1/watch/exercise?name=done`). Fixed: `currentExerciseName()` now
returns `""` once the workout is finished, `requestExerciseInfo()` never fetches
that empty name, and every screen that would have shown it (`ExerciseInfoView`,
`ExerciseHistoryView`, `ExerciseStatsView`, and the set screen's "done" branch)
instead renders a **"WORKOUT COMPLETE"** summary: day title, `N of M sets`,
elapsed time, and the activity/sync notes.

There was also, before this date, **no way to leave the app**: `BACK` on a
finished workout opened the "edit set" screen for a set that no longer existed,
and the finish menu was the only thing BACK/SELECT ever popped, so the user was
stuck on the DONE screen with no path to the day picker or out of the app
entirely. Fixed:

- `BACK` on the finished set screen now pops to the day picker instead of
  opening the edit screen.
- Hold `SELECT` on the set screen's options menu gained an **"Exit app (session
  kept)"** item — saves the cursor and calls `System.exit()`. The next launch
  restores the session via `onStart`/`restore()`.
- Hold `SELECT` on the day picker gained an **"Exit app"** item for the same
  reason, since BACK there is the picker's "choose" action, not an exit.

Choosing Save/Discard still leaves the DONE summary on screen (it reports
`saved to Garmin` / `synced to Liftosaur` / the failure, exactly as before) —
only the cursor position is what determines "finished", and it is deliberately
**not** reset by `resolveSave()` so this summary and the BACK-to-picker fix both
keep working after the workout resolves. (`selectDay()` already resets the
cursor and every editable field the next time any day is chosen, so this does
not leak into a future workout.)

## Persistence

Progress is written to `Application.Storage` on every set, and `onStart`
restores an interrupted session, so leaving the app mid-workout does not lose
the session. Storage accepts only scalars, so the nested per-set arrays are
serialised to strings (`"220,250,285"` and a `"0101"` bit string) rather than
stored as nested arrays — which the API rejects.

## Controls (Venu 2S: SELECT, BACK, touchscreen — no up/down buttons)

| Input | On the set screen | During rest | On the AMRAP step |
|---|---|---|---|
| `SELECT` (top-right) / tap | log the set | end the rest | confirm the reps |
| swipe up / down | weight +/- 5 lb | rest +/- 15 s | reps +/- 1 |
| `BACK` | step back a set (or, once finished, return to the day picker) | end the rest | confirm the reps |
| long-press `SELECT` | menu: view workout, exercise info, skip exercise, end workout, **exit app (session kept)** | | |

The day picker also has a long-press `SELECT` menu now, with a single **"Exit
app"** item — `BACK` on the picker stays the "choose this day" action, so it
needed its own way out.

## Exercise history (swipe down from the set screen)

Swiping down from the set screen fetches the exercise's recent sessions from
the backend and, once loaded, shows a **native scrolling list** (`Menu2`) —
one row per session (`historyLabel`/`historySublabel`, e.g. "Sep 10  -  top
305" / "5x220  5x250  5+x285"), tap a row for that session's full set
breakdown plus top weight/e1rm/volume, `BACK` from the detail returns to the
list, `BACK` from the list returns to the set screen. Before 2026-09-18 this
was a fixed 5-line block with no per-line length cap, which overflowed the
round bezel on long histories; the server also now sends up to 12 sessions
instead of 5 (`app/plan.py`'s `exercise_history()`), still capped small enough
to stay well under 4 KB over the https tunnel.

## Duration, week, and day fields (corrected 2026-09-18)

- **Duration** is wall-clock (`Time.now().value()` at start vs. at read time),
  not `System.getTimer()` — the timer counts from device *boot*, so a session
  restored after a watch restart used to report the device's uptime as the
  workout duration (one real payload showed `duration: 27138s`, 7.5 hours, for
  a ~45 minute session). Clamped to `[0, 21600]` seconds so a bad clock can
  never write an absurd number into the Liftosaur record.
- **`week`/`dayInWeek`** are derived from the chosen day's section ("Week 3" ->
  3) and name ("Day 4" -> 4), not from the day's index in the full list.
  Because the day list spans every week-block (all four weeks, deload
  included), the index into it is not the day-of-week — a Week 3 day used to
  upload as `week: 1, dayInWeek: 15` and land in the wrong slot in Liftosaur.

Stepping back **un-logs** the set so it can be redone. The menu's "next set"
skips *without* logging, which `SELECT` deliberately does not do (it would record
a set that never happened — that was a real bug: skipping a rest used to log the
following set).

## Two Monkey C traps this app hit

**`"\u00b7"` is not an escape.** Monkey C does not process `\uXXXX`; it prints
them literally, so hints rendered as `/u00b7`. Use plain ASCII (or literal UTF-8
characters) in strings.

**A `WatchUi.Confirmation` answers NO when dismissed with BACK.** The finish
prompt used one, so a stray BACK silently *discarded* the workout — which looked
exactly like "the app exits but nothing saves". It is now a `Menu2` with
**Save & finish** first, and popping the menu without choosing keeps the session
open so nothing can be lost by accident.

## What the Garmin Connect activity can and cannot contain

The request was for sets/reps/weight, heart rate, and accelerometer data on the
activity itself (not just in Liftosaur). On the Venu 2S, three native APIs that
would have made this easy simply **do not exist** (checked against
`venu2s.api.debug.xml`):

| Missing API | Consequence |
|---|---|
| `ActivityRecording.Session.addSets()` / `createSet()` / `SetType` | no *native* Garmin strength sets with reps/weight — laps + developer fields are the only route |
| `ActivityRecording.Session.addInformation()` | cannot inject arbitrary samples into the built-in metrics stream |
| `Sensor.SensorLogging.enableSensorLogging()` | **cannot write a raw sensor stream (HR or accelerometer) into the FIT file** — this is why raw accelerometer data cannot live in the FIT at all, at any sample rate, on this device |

What IS available instead, and what this app does with it (2026-09-18):

- `Session.addLap()` — every completed set adds one FIT **lap**, and each lap
  now carries **FIT developer fields**: `Exercise` (string), `SetIndex`,
  `Weight`, `Reps`, `Amrap`, `Rest` — the real per-set data the activity was
  missing. Written by `setLapFields()` in `Workout.mc`, immediately before
  `addLap()` (the LAP message snapshots field values at that call).
- `ActivityRecording.Session.createField()` (`Toybox.FitContributor`) —
  developer fields, placed on `RECORD` (per-second), `LAP` (per-set), or
  `SESSION` (summary) messages:

  | Field | id | mesgType | Type | Meaning |
  |---|---|---|---|---|
  | `Exercise` | 0 | LAP | STRING | exercise name for the set just completed |
  | `SetIndex` | 1 | LAP | UINT8 | 1-based set number within the exercise |
  | `Weight` | 2 | LAP | UINT16 (lb) | weight for that set |
  | `Reps` | 3 | LAP | UINT8 | reps performed |
  | `Amrap` | 4 | LAP | UINT8 | 1 if the set was an AMRAP set |
  | `Rest` | 5 | LAP | UINT16 (s) | prescribed rest after the set |
  | `PeakG` | 6 | LAP | FLOAT (G) | peak accelerometer magnitude during the set |
  | `MeanG` | 7 | LAP | FLOAT (G) | mean accelerometer magnitude during the set |
  | `RepsEst` | 8 | LAP | UINT8 | accelerometer-derived rep count estimate |
  | `Samples` | 9 | LAP | UINT16 | accelerometer samples collected for the set |
  | `SetsDone` | 10 | SESSION | UINT8 | total logged sets |
  | `Volume` | 11 | SESSION | UINT32 (lb) | sum of weight x reps over logged sets |
  | `AccelRate` | 12 | SESSION | UINT8 (Hz) | accelerometer sample rate actually granted |
  | `HeartRate` | 20 | RECORD | UINT8 (bpm) | one write per second from `Sensor.getInfo().heartRate` |
  | `HeartRateAvg` | 21 | SESSION | UINT8 (bpm) | average of the per-second HR field |
  | `HeartRateMax` | 22 | SESSION | UINT8 (bpm) | max of the per-second HR field |

  Every `createField()`/`setData()` call is wrapped in `try`/`catch` — a
  developer field is a bonus, and its failure must never cost the workout
  itself (see "Risks" in the plan: if `createField` throws, it is logged with
  `System.println` and the rest of the workout proceeds with that field simply
  absent).
- The activity name now carries the section too: `"Liftosaur - Day 1 (Week 1)"`.
- The finish screen reports what happened (`saved to Garmin`, `nothing to save`,
  `activity not started`) because a silent failure here is indistinguishable
  from success.

Per-set reps and weight are ALSO recorded in Liftosaur itself, via the
sync-back in docs/06 — that remains the source of truth for training history;
the FIT developer fields make the same data visible in the Garmin Connect
activity/FIT file directly.

### Heart rate and the zones caveat

The onboard HR sensor is now explicitly enabled at workout start
(`Sensor.enableSensorType(Sensor.SENSOR_ONBOARD_HEARTRATE)` plus
`Sensor.enableSensorEvents(...)`), because the measured baseline (four real
activities pulled from the watch on 2026-09-18) showed native HR at 100% on
some app-recorded sessions and completely absent (0%) on others. On top of
that, a 1 Hz timer independently writes `Sensor.getInfo().heartRate` to the
`HeartRate` developer field every second, so the activity always has *a* HR
graph even on a session where the native stream fails to lock.

**Honest limitation:** Garmin Connect computes *time in heart-rate zones* from
the device's own **native** `heart_rate` record field (and the resulting
`hr_zone`/`time_in_zone` FIT messages) — NOT from our developer field. The
`HeartRate` developer field is a chart and a summary stat, never a zone
source. `inspect_fit.py` reports "native HR present: yes/no" explicitly so a
verification run never claims zones it did not actually produce.

### Accelerometer: per-set metrics only, never raw, and a deliberate scope cut

`Sensor.registerSensorDataListener()` is used to sample the accelerometer at
up to 25 Hz (clamped to `Sensor.getMaxSampleRateForSensorType(:accelerometer)`
if the device offers less). The callback (`onAccelData`) accumulates, per set:
sample count, sum and peak of the acceleration magnitude, and a rep-count
estimate from magnitude peaks crossing a hysteresis band (1.3 G up / 1.1 G
down, in `Workout.mc`'s `ACCEL_HIGH_MILLI_G`/`ACCEL_LOW_MILLI_G`). These
accumulators reset every time a lap is written (`setLapFields()`), because
each lap is exactly one set. Weight-0 sets (`Chin Up`, `Plank`) are handled
correctly because nothing here ever divides by weight.

Because `Sensor.SensorLogging.enableSensorLogging()` does not exist on this
device (see the table above), there is **no way to store the raw
accelerometer stream in the FIT file** — the per-set summary fields above are
the ceiling of what this device can record, not a shortcut. Streaming the raw
track to our own backend (which already has a physics/rep-detection pipeline,
`POST /api/v1/sets`) was offered and **the user deliberately declined it**
(2026-09-18): "Garmin activity only — no network, everything stays on the
watch." That path (`RecordingController.mc`, `SampleBuffer.mc`,
`backend/python/app/main.py`) is untouched by this decision.

Registering the accelerometer listener for the whole workout costs battery;
this app keeps the field set small (four LAP fields + one SESSION field) and
only requests it at all if the workout actually started recording.

## Auto-exit after Save/Discard (2026-09-18)

Before this date the app never closed itself — the user had to know about the
hold-`SELECT` "Exit app" menu items. Now:

- **Discard** exits immediately once `session.discard()` returns — nothing to
  wait for.
- **Save** stays on the DONE screen (showing `closing...` once the exit is
  pending) until the Liftosaur upload resolves — success or failure, both
  finish the exit — **or** an 8-second watchdog timer fires, whichever comes
  first. This means a slow or unreachable backend can never hang the app: the
  workout is safely stashed for retry (existing behaviour) and the app closes
  on schedule regardless.
- If there was nothing to upload (e.g. no sets were logged), Save exits
  immediately like Discard — there is no network call to wait for.
- While an exit is pending, `finishWorkout()` (top-button hold, the "End
  workout" menu item, and the top-button single press once finished) becomes a
  no-op, so the finish menu can't be reopened out from under the closing app.

## Persistence

## Known gaps

- **Reps are display-only.** Correcting an AMRAP set's actual reps needs a
  press/long-press input scheme verified on hardware; weights are editable now.
- Sync-back to Liftosaur now works over https (docs/06) — the "needs https"
  gap this line used to describe is resolved; what's still open is
  **hardware confirmation**: the fixed `Comms.urlEncode()` (2026-09-18) has
  only been proven with the Python mirror in `tools/verify_watch_payload.py`,
  not yet by an actual Save & finish on the device.
- The deload section is parsed but not offered in the picker.
- Weights come from `rm1`; if Liftosaur's `progress:` scripts have already moved
  the training max, the watch's numbers lag until the plan is regenerated.
- **Hardware confirmation for the FIT developer fields, HR, accelerometer, and
  auto-exit (2026-09-18) is still open.** All four build cleanly and pass
  `check-device-api.py`, but "the symbol exists" and "the device actually
  accepts the call at runtime" are different claims — `createField()` failing
  at runtime, the accelerometer listener never delivering data, or the 8-second
  exit watchdog behaving unexpectedly are all real possibilities the plan
  itself calls out as risks. `PROGRESS-FIT.md` has the exact device protocol;
  it has not yet been run.
