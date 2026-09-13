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
| `BACK` | step back a set | end the rest | confirm the reps |
| long-press `SELECT` | menu: next set, previous set, skip exercise, finish | | |

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

The request was for sets/reps/weight on the activity. On the Venu 2S that is
partly impossible:

- `ActivityRecording.addSets()`, `createSet()` and `SetType` **do not exist** on
  this device (checked against `venu2s.api.debug.xml`), so a structured
  strength workout — native sets with reps and weight — cannot be written.
- `Session.addLap()` **does** exist, so every completed set adds a lap. That
  gives the activity real content and per-set timing.
- The activity name carries the day (`Liftosaur - Day 1`) and the sport is a
  strength training workout.
- The finish screen reports what happened (`saved to Garmin`, `nothing to save`,
  `activity not started`) because a silent failure here is indistinguishable
  from success.

Per-set reps and weight ARE recorded — in Liftosaur, via the sync-back in
docs/06. It is the app that owns the training data.

## Known gaps

- **Reps are display-only.** Correcting an AMRAP set's actual reps needs a
  press/long-press input scheme verified on hardware; weights are editable now.
- No sync-back to Liftosaur (needs https; see above).
- The deload section is parsed but not offered in the picker.
- Weights come from `rm1`; if Liftosaur's `progress:` scripts have already moved
  the training max, the watch's numbers lag until the plan is regenerated.
