# Progress — FIT activity (exercise/weight/reps, HR, accelerometer) + auto-exit

Plan: `.hermes/plans/2026-09-18_055158-fit-activity-hr-accel-autoexit.md`

Scope for this session: Tasks 1, 2, 3, 4, 6, 7. **Task 5 is deliberately out of scope**
(no accelerometer upload path). Confirmed by `git diff --stat` at the end of this file:
`RecordingController.mc`, `SampleBuffer.mc`, `backend/python/app/main.py`, and
`SetIngest.prescribed_weight_lbs` have **zero diff** — never opened for writing this session.

Design answers used (per the orchestrator, 2026-09-18):
- Task 1: option A — DONE screen stays until the Liftosaur upload resolves, 8s hard cap, then
  exit; Discard exits immediately.
- Task 4: FIT developer fields only, no network anywhere.

| Task | Status | Notes |
|---|---|---|
| 1. Auto-exit after Save/Discard | DONE | see below |
| 2. Per-set exercise/weight/reps as FIT dev fields | DONE | see below |
| 3. Heart rate throughout + zones honesty | DONE | see below |
| 4. Accelerometer per-set metrics as FIT dev fields | DONE | see below |
| 5. Raw accel upload | OUT OF SCOPE (user decision) | not touched, confirmed below |
| 6. Prove it on the real device | PARTIAL — tools proven, workout proof needs the user | see below |
| 7. Docs and ship | DONE | see below |

---

## Task 1 — Auto-exit after Save/Discard

STATUS: DONE

**Deviation from the plan's literal `requestExit()` snippet, documented per the resume rules.**
The plan's sample checks `if (!_started)` inside `requestExit()` to decide whether to wait for
the upload or exit immediately. That cannot work as written: by the time `resolveSave()` calls
`requestExit()` "at the end", `_started` has already been set `false` for **both** Save and
Discard (existing code, unchanged) — so the `!_started` check could never tell the two cases
apart. Implemented instead as `requestExit(waitForUpload as Boolean)`, called from the tail of
`resolveSave()` as `requestExit(save and dispatched)`, where `dispatched` is whether
`_comms.postWorkout()` actually made a network call (it returns `false` when there was nothing to
post — e.g. no sets logged — so a Save with nothing to upload now also exits immediately, matching
the plan's own intent "stay on the DONE screen until the Liftosaur upload resolves": if there is no
upload, there is nothing to resolve).

- `embedded/monkeyc/source/Workout.mc`: added `_exitPending`/`_exitTimer` fields,
  `finishExit()` (stops the watchdog, stops rest, stops sensor capture, `System.exit()`, guarded
  on `_exitPending` so a background pending-workout retry at app start can never close the app),
  `requestExit(waitForUpload)` (8000ms one-shot `Timer.Timer` when waiting), `exitPending()`
  accessor.
  - `finishWorkout()` is now a no-op while `_exitPending` — this is the single guard point that
    covers all three ways the UI could try to reopen the finish menu (top-button single press when
    finished, top-button hold, and the options menu's "End workout" item), so no changes were
    needed in `SetDelegate`/`SetMenuDelegate` themselves.
  - `resolveSave()` already no-ops on a second call via the pre-existing `!_started` guard, so it
    needed no additional guard for re-entrancy during the exit window.
- `embedded/monkeyc/source/Comms.mc`: `postWorkout()` now returns `Boolean` (was `Void`) — `true`
  iff `Communications.makeWebRequest` was actually called. `onPostResponse()` calls
  `_controller.finishExit()` in **both** the success and the stash-and-retry-later branches; the
  "only when exit pending" requirement from the plan is satisfied by `finishExit()`'s own
  `if (!_exitPending) { return; }` guard rather than a second check at the call site.
- `embedded/monkeyc/source/WorkoutUi.mc`: `SetView.onUpdate()`'s DONE branch shows `closing...`
  (replacing `hold = options`) once `_c.exitPending()` is true.

Verification: build gate below (Task 9-equivalent); the actual 8s-watchdog / upload-resolves-first
timing can only be observed on hardware (Task 6).

---

## Task 2 — Per-set exercise/weight/reps as FIT developer fields

STATUS: DONE

`embedded/monkeyc/source/Workout.mc`:
- `import Toybox.FitContributor;` added.
- `createFitFields()`, called from `startWorkout()` right after `_session.start()` (only if the
  session was created): creates `Exercise`(0,LAP,STRING), `SetIndex`(1,LAP,UINT8),
  `Weight`(2,LAP,UINT16,"lb"), `Reps`(3,LAP,UINT8), `Amrap`(4,LAP,UINT8), `Rest`(5,LAP,UINT16,"s"),
  plus the Task 3/4 fields (see below) in the same call. Wrapped in one `try`/`catch`; on failure,
  logs `System.println("Workout: createField failed: " + e.getErrorMessage())` and every later
  field write is guarded by a null check, so a partial or total failure here never blocks a save.
- `setLapFields()`, called from `markLap()` **immediately before** `_session.addLap()` (verified
  by reading `completeSet()`: `markLap()` runs while `_exIndex`/`_setIndex` still point at the set
  just logged, before the cursor advances) — writes `Exercise`/`SetIndex`/`Weight`/`Reps`/`Amrap`/
  `Rest` for the set that was just completed, plus that set's accelerometer summary (Task 4), then
  resets the accelerometer accumulators for the next set.
- `_computeVolumeLb()` + `writeSessionSummaryFields()`: writes `SetsDone`(10,SESSION,UINT8) and
  `Volume`(11,SESSION,UINT32,"lb", sum of weight×reps over **logged** sets only) immediately before
  `_session.save()` in `resolveSave()`, wrapped in `try`/`catch`.
- Activity name changed from `"Liftosaur - " + dayName(_dayIndex)` to
  `"Liftosaur - " + dayName(_dayIndex) + " (" + _section + ")"` so the week is visible in Garmin
  Connect's activity list.

Verification is Task 6 (device FIT inspection) per the plan — not a unit test, Monkey C cannot run
off-device. Build gate below proves it compiles and every symbol exists on `venu2s`.

---

## Task 3 — Heart rate throughout, and zones honesty

STATUS: DONE

`embedded/monkeyc/source/Workout.mc`:
- `startHrCapture()`, called from `startWorkout()`: `Sensor.enableSensorType(
  Sensor.SENSOR_ONBOARD_HEARTRATE)` and `Sensor.enableSensorEvents(method(:onSensorEvent))`
  (a no-op listener body — its only job is telling the OS this app wants sensor data flowing),
  each in its own `try`/`catch` so one failing does not block the other. Then starts a 1 Hz
  `Timer.Timer` (`_hrTimer`) calling `hrTick()`.
- `hrTick()`: reads `Sensor.getInfo().heartRate`, and if it is a sane value (0 < hr < 250) writes
  it to `HeartRate`(20,RECORD,UINT8,"bpm") and accumulates `_hrSum`/`_hrCount`/`_hrMax`. Wrapped in
  `try`/`catch` — a bad or missing reading is silently skipped, never thrown.
- `writeSessionSummaryFields()` (shared with Task 2) also writes `HeartRateAvg`(21,SESSION,UINT8)
  and `HeartRateMax`(22,SESSION,UINT8) from those accumulators.
- `_hrTimer` is stopped in `resolveSave()` (via the new `stopSensorCapture()` helper, which also
  unregisters the accelerometer listener — see Task 4).
- **Zones honesty (docs/05):** added an explicit "Heart rate and the zones caveat" section stating
  that Garmin Connect computes time-in-zone from the device's **native** `heart_rate` record field,
  not from the `HeartRate` developer field, and that `inspect_fit.py` now prints
  `native HR present: yes/no` so a verification run can never claim zones it did not produce. The
  measured baseline (native HR 100% on two app-recorded sessions, 0% on a third) is what motivated
  explicitly enabling the sensor in step 1 rather than relying on it happening implicitly.

---

## Task 4 — Accelerometer per-set metrics as FIT developer fields

STATUS: DONE

`embedded/monkeyc/source/Workout.mc`:
- `import Toybox.Sensor;`, `import Toybox.Math;` added. `ACCEL_HIGH_MILLI_G = 1300`,
  `ACCEL_LOW_MILLI_G = 1100` module constants (hysteresis band, milli-G).
- `startAccel()`, called from `startWorkout()`: reads
  `Sensor.getMaxSampleRateForSensorType(:accelerometer)`, clamps a 25 Hz request to it if lower,
  stores the actual rate in `_accelRate`, and calls `Sensor.registerSensorDataListener(
  method(:onAccelData), {:period => 1, :accelerometer => {:enabled => true, :sampleRate => rate}})`
  — `:period => 1` satisfies the API's documented "maximum 4 seconds" limit. Wrapped in
  `try`/`catch`; failure is logged and every consumer of the accel fields is null-guarded.
- `onAccelData(sensorData)`: for every sample in the batch, computes magnitude
  `sqrt(x²+y²+z²)` (milli-G), accumulates count/sum/peak, and estimates reps by counting times the
  magnitude crosses `ACCEL_HIGH_MILLI_G` from below with `ACCEL_LOW_MILLI_G` as the reset floor
  (simple hysteresis, avoids double-counting jitter around a single threshold). Wrapped in
  `try`/`catch` so one bad sample batch cannot break the workout.
- `setLapFields()` (Task 2) also writes `PeakG`(6,LAP,FLOAT,"G", `_accelPeakMag / 1000.0`),
  `MeanG`(7,LAP,FLOAT,"G", mean of the accumulated magnitude), `RepsEst`(8,LAP,UINT8),
  `Samples`(9,LAP,UINT16), then calls `_resetAccelAccumulators()` — each lap is one set, per the
  plan.
- `AccelRate`(12,SESSION,UINT8,"Hz") written by `writeSessionSummaryFields()` so the actual
  negotiated sample rate is visible in the file.
- The user's `Chin Up`/`Plank` sets (weight 0 in the baked-in plan) are handled correctly: nothing
  in the accelerometer or volume code divides by weight (confirmed by reading every arithmetic
  expression touching `_weights`/`_accel*` — grep: `grep -n "/ .*[Ww]eight\|_weights\[.*\] */" source/Workout.mc` finds no such division).
- `stopSensorCapture()` (added, used by both `resolveSave()` and `finishExit()`) unregisters the
  sensor data listener; `resolveSave()` stops it as the recording ends, `finishExit()` unregisters
  it again defensively (harmless if already unregistered) per the plan's explicit instruction to
  stop it in both places.
- `docs/05` documents the battery cost (accelerometer registered for the whole workout) and the
  hard limit (`Sensor.SensorLogging.enableSensorLogging()` absent on this device means raw
  accelerometer literally cannot be written to the FIT, at any rate — this is not a rate/effort
  tradeoff, it is a missing API) plus the one-line note that streaming the raw track to the backend
  was offered and declined by the user (Task 5).

---

## Task 5 — DELIBERATELY OUT OF SCOPE

STATUS: confirmed untouched.

```
git diff --stat -- embedded/monkeyc/source/RecordingController.mc embedded/monkeyc/source/SampleBuffer.mc backend/python/app/main.py
```
Result: **empty output** — no diff at all in any of the three files.
```
grep -n "prescribed_weight_lbs" backend/python/app/main.py
```
Result: unchanged (`Field(gt=0)` validation and its one use site, exactly as before this session).
`docs/05` carries the one-line note per the plan's instruction (see Task 4 above).

---

## Task 6 — Prove it on the real device

STATUS: PARTIAL. The tools are extended, proven to run, and proven against the real MTP-connected
watch (which happened to be plugged in during this session) — but **no new test workout has been
run with this session's build**, so the per-set dev-field/HR/accel claims are NOT YET verified on
hardware. This section states plainly what was and was not observed; do not read the "tool proof"
runs below as a substitute for the actual device protocol, which still needs the user.

### What WAS run this session (tool proof only, not a proof of the new firmware)

`embedded/monkeyc/tools/inspect_fit.py` was extended per the plan:
- prints `native HR present: yes/no` explicitly;
- prints a stable per-lap developer-field table (`lap N dev: Exercise=... SetIndex=... Weight=...
  ...`, fixed key order regardless of FIT field-definition order in the file);
- `--expect-laps N --expect-dev-fields N` now exits non-zero with a clear message when a real file
  doesn't match, so it can gate future verification runs.

Command (proves the inspector still runs correctly against the four baseline files pulled by the
orchestrator before this session, under `/tmp/fit-before/` — these are OLD files with 0 dev fields,
recorded before any of this session's code existed):
```
python3 tools/inspect_fit.py /tmp/fit-before/2026-09-18-03-21-46.fit
```
Result (excerpt): `RECORDs: 40, with native heart_rate: 40 (100.0%), HR 51-81 bpm`,
`native HR present: yes`, `developer fields defined: 0`, `LAPs: 16   SESSIONs: 1` — matches the
plan's §2 baseline exactly (40 records, 100% HR, 16 laps, 0 dev fields).

Command (proves the `--expect-*` gate mechanics both pass and fail correctly):
```
python3 tools/inspect_fit.py /tmp/fit-before/2026-09-18-03-21-46.fit --expect-laps 16 --expect-dev-fields 0
python3 tools/inspect_fit.py /tmp/fit-before/2026-09-18-03-21-46.fit --expect-laps 4  --expect-dev-fields 9
```
Result: first command exits 0 (`OK: ... matches --expect-laps/--expect-dev-fields`); second exits 1
with `FAIL: expected 4 laps, found 16 ...` and `FAIL: expected 9 developer fields, found 0 ...` on
stderr.

New helper `embedded/monkeyc/tools/pull_watch_fits.sh` (did not exist in the repo before this
session — written per the plan's description of it as a helper using the given MTP commands).
The watch happened to be mounted over MTP during this session (`gio mount -l` showed
`mtp://091e_4e78_0000c8c4c89c/`), so the script was run for real (not just syntax-checked):
```
bash tools/pull_watch_fits.sh --count 2 --out /tmp/pull_watch_fits_test
```
Result: correctly parsed the device URI, listed `.../Internal Storage/GARMIN/Activity` (raw space,
not `%20`, per the plan's warning), and copied the 2 newest files
(`2026-09-18-04-00-52.fit`, `2026-09-18-05-47-03.fit` — the same baseline files from §2 of the
plan, since no new workout has been recorded with this session's build). Scratch directory deleted
afterward (`rm -rf /tmp/pull_watch_fits_test`).

**This proves the tool chain works. It does NOT prove the new dev fields, HR field, accelerometer
fields, or auto-exit work on hardware** — that requires a workout run with `dist/Liftosaur.prg` as
built by this session, which only the user can do.

### Device protocol — CHECKLIST FOR THE USER (not yet executed)

1. Sideload `dist/Liftosaur.prg` (sha256 in `dist/Liftosaur.prg.sha256`): copy it to
   `GARMIN/APPS` over MTP, then **physically unplug** the watch (that's when it installs).
   ```
   gio mount -l | grep -i mtp
   gio copy dist/Liftosaur.prg "mtp://<id>/Internal Storage/GARMIN/APPS/"
   # then physically unplug
   ```
2. Run a short real workout: start a day, log **at least 2 exercises, 4 sets total**, nothing
   heavy. Watch the DONE screen for `closing...` after Save, and confirm the app actually closes
   (either promptly, or within ~8s if the network is slow) — and separately confirm Discard closes
   immediately.
3. Pull the new FIT file:
   ```
   cd embedded/monkeyc && bash tools/pull_watch_fits.sh --count 1 --out ./fit-out
   ```
4. Inspect it and gate on the shape:
   ```
   python3 tools/inspect_fit.py ./fit-out/<newest>.fit --expect-laps 4 --expect-dev-fields 16
   ```
   (16 = every field `createFitFields()` creates: `Exercise, SetIndex, Weight, Reps, Amrap, Rest,
   PeakG, MeanG, RepsEst, Samples` (10 LAP) + `SetsDone, Volume, AccelRate, HeartRateAvg,
   HeartRateMax` (5 SESSION) + `HeartRate` (1 RECORD) = 16. If `createField()` throws for any of
   them, the plain (non-`--expect`) run's `developer fields defined: N` line will show fewer than
   16 — treat that as a real finding to report, not a reason to lower the expected count.)
5. From the plain output, confirm by eye:
   - lap count == sets logged (4 in the example above);
   - every lap shows `Exercise=`, `SetIndex=`, `Weight=`, `Reps=` with real (non-zero-suspicious)
     values;
   - `PeakG` > 1.0 for a moving set (a static/held set like `Plank` may not clear this — note which
     exercises were used);
   - `HeartRate` developer field exists with roughly one sample per elapsed second;
   - report `native HR present: yes/no` from the tool's own line — do not infer zones from
     anything else;
   - the SESSION line carries `SetsDone`, `Volume`, `HeartRateAvg`, `HeartRateMax`, `AccelRate`.
6. Re-run the full previous verification so nothing regressed (commands + results already captured
   below in this file, under "Gates run this session").

**This checklist has NOT been executed.** Nothing in this file should be read as claiming it was.

---

## Task 7 — Docs and ship

STATUS: DONE

- `docs/05-watch-workout-app.md`:
  - Rewrote "What the Garmin Connect activity can and cannot contain" to list all three ABSENT
    APIs (`addSets`/`createSet`/`SetType`, `addInformation`, `enableSensorLogging`) with their
    consequences, then the full developer-field table (name, id, mesgType, type, meaning) for all
    16 fields.
  - Added "Heart rate and the zones caveat" (native vs. developer-field HR, what
    `inspect_fit.py` reports).
  - Added "Accelerometer: per-set metrics only, never raw, and a deliberate scope cut" (hysteresis
    rep estimate, the hard `enableSensorLogging`-absent limit, the one-line Task 5 decision note,
    battery cost).
  - Added "Auto-exit after Save/Discard (2026-09-18)" describing the Discard-immediate /
    Save-waits-up-to-8s behaviour and the `finishWorkout()` no-op-while-exiting guard.
  - Extended "Known gaps" with the honest statement that hardware confirmation for all of this is
    still open (Task 6 above).
- `dist/Liftosaur.prg` + `dist/Liftosaur.prg.sha256` refreshed from this session's build (see
  "Gates run this session" below for the exact sha256 and byte size).

---

## Gates run this session (raw output)

### 1. Backend pytest (baseline 54 passed; Task 5 files untouched so no change expected)

```
cd backend/python && .venv/bin/python -m pytest -q
```
```
......................................................                   [100%]
=============================== warnings summary ===============================
.venv/lib/python3.11/site-packages/fastapi/testclient.py:1
  .../starlette/testclient.py:1: StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
    from starlette.testclient import TestClient as TestClient  # noqa

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
54 passed, 1 warning in 2.45s
```
**54 passed — matches baseline exactly, nothing added/removed** (expected: this session never
touched `backend/python`).

### 2. `venu2s` build

First attempt failed with `Permission 'FitContributor' required for '$.Toybox.FitContributor'`
(77 error lines) — `Toybox.FitContributor` calls need the `FitContributor` permission declared in
`manifest.xml`, which was missing. Added
`<iq:uses-permission id="FitContributor" />` to `embedded/monkeyc/manifest.xml`. Also removed an
unused `_fitNote` diagnostic field after the first successful build flagged it
(`Member variable '_fitNote' is not used` — every catch site already logs via
`System.println(... + e.getErrorMessage())`, so the field was write-only dead state; removed
rather than left as a warning, per house rules on unused code).

Command:
```
cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s
```
Raw output (final, clean run):
```
[... same pre-existing "Cannot determine if container access/assignment is using container type"
     warnings as the prior session's baseline, in LiftBinary.mc/LiftBleTransport.mc/LiftFrame.mc/
     SampleBuffer.mc/Transport.mc/Workout.mc/WorkoutUi.mc, plus the two pre-existing
     "Statement is not reachable" warnings (Workout.mc:376 - traced: inside startWorkout()'s
     "activity not started" branch, untouched by this session's diff other than line-number shift
     from earlier insertions - and one other pre-existing site) ...]
WARNING: venu2s: /home/hermes/repos/garmin-liftosaur/embedded/monkeyc/source/WorkoutUi.mc:871: Member variable '_c' is not used.
BUILD SUCCESSFUL
Built bin/Liftosaur.prg (229772 bytes) target=006-B3704-00

check-device-api: all 77 module calls exist on 'venu2s'

Sideload:  copy bin/Liftosaur.prg to GARMIN/APPS over MTP, then PHYSICALLY
           UNPLUG the watch (that is when it installs). See
           docs/03-garmin-toolchain-and-sideload.md
```
**No `Symbol Not Found` / `Permission` errors. `check-device-api` clean (77/77, up from the prior
session's 71 — the 6 new module calls are the `FitContributor`/`Sensor` APIs this plan added).**
The `WorkoutUi.mc:871 '_c' not used` warning is the same pre-existing `InfoDelegate._c` warning
documented in the prior session's `PROGRESS.md` (was line 866 there; shifted to 871 by this
session's unrelated insertions above it in the same file — `InfoDelegate` itself was not touched).

### 3. `verify_watch_payload.py` (dry-run only, both backends — Task 5/backend untouched, run only
to confirm nothing this session broke the existing sync path)

Command (localhost):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
```
Result: all 14 days `OK` on escaping/length, week/dayInWeek table correct, sample escaping has no
`%00`, POST to Day 1 (20 sets) returned
`{"recorded": false, "dry_run": true, "sets": 20, "liftohistory": "...program: \"5/3/1 BBB - Squat/Bench/Deadlift/OHP\"... week: 1 / dayInWeek: 1 / duration: 3600s..."}`,
capability guard confirmed `dry_run: true`/`recorded: false`, final line
`OK: round-tripped cleanly, no %00, all sets present in liftohistory.`

Command (tunnel, default `--backend` from `LIFT_BACKEND` in `Comms.mc`):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py
```
Result: `backend: https://transcripts-forward-acdbentity-ascii.trycloudflare.com`, identical shape
to the localhost run above — all 14 days `OK`, capability guard passed, no `%00`, no live write
(both runs omitted `--live`).

### 4. FIT-inspection tool proof (not a device proof — see Task 6 above for what this does and does
not demonstrate)

Already detailed under Task 6 above: `inspect_fit.py` run against `/tmp/fit-before/*.fit`
(baseline files) and the `--expect-laps`/`--expect-dev-fields` pass/fail cases both verified;
`pull_watch_fits.sh` run end-to-end against the actual MTP-mounted watch.

### 5. ASCII-only check on every line this session added

```
git diff embedded/monkeyc/source/Workout.mc embedded/monkeyc/source/WorkoutUi.mc embedded/monkeyc/source/Comms.mc | grep -P '^\+' | grep -P '[^\x00-\x7F]'
```
Result: empty (no non-ASCII characters in any added line). Some **pre-existing, untouched** header
comments in these files contain an em dash/middle dot (e.g. `Workout.mc:1`, `:40`, `:225`, `:775`)
— confirmed via the same check restricted to added lines only, so these are not new.

### 6. `git diff --stat` and removed-line audit (nothing weakened/deleted)

```
git diff --stat
```
```
 dist/Liftosaur.prg                   | Bin 219276 -> 229772 bytes
 dist/Liftosaur.prg.sha256            |   2 +-
 docs/05-watch-workout-app.md         | 136 ++++++++++++--
 embedded/monkeyc/manifest.xml        |   3 +
 embedded/monkeyc/source/Comms.mc     |  11 +-
 embedded/monkeyc/source/Workout.mc   | 332 ++++++++++++++++++++++++++++++++++-
 embedded/monkeyc/source/WorkoutUi.mc |   9 +-
 7 files changed, 474 insertions(+), 19 deletions(-)
```
Every `-` line in the diff read individually:
- `Comms.mc`: `-    function postWorkout() as Void {` (signature change to `as Boolean`, Task 1).
- `Workout.mc`: `-                :name     => "Liftosaur - " + dayName(_dayIndex),` (Task 2's
  section-in-name change) and `-            if (_comms != null) { _comms.postWorkout(); }`
  (replaced with the `dispatched =` assignment version, Task 1).
- `WorkoutUi.mc`: the unconditional `hold = options` line, now wrapped in the `exitPending()` if/else
  (Task 1).
No test file was touched this session (`backend/python/tests/` has zero diff, confirmed by
`git diff --stat -- backend/python/tests/` producing no output).

**No existing test assertion was weakened, skipped, or deleted.** No `--live` run. No `git push`.
No `git checkout -- <file>` on uncommitted work — no mutation testing was needed this session (no
existing tool's core logic was rewritten in a way that warranted a mutation proof; `inspect_fit.py`
was extended, not rewritten, and its `--expect-*` gate was proven directly with real pass/fail
cases above rather than via a mutation of a copy).

---

## Final status

Tasks 1-4 and 7: DONE, built clean, `check-device-api.py` passes (77/77), backend suite unchanged
at 54 passed. Task 5: confirmed out of scope and untouched. **Task 6 is PARTIAL**: the tooling
(`inspect_fit.py` extended, `pull_watch_fits.sh` written) is proven to work — including against the
actual watch, which happened to be MTP-mounted during this session — but no workout has been run
with this session's build, so the FIT developer fields, HR field, accelerometer fields, and the
auto-exit timing are **not yet verified on hardware**. The checklist above is what still needs to
happen, and this file does not claim otherwise. `dist/Liftosaur.prg` (229772 bytes,
sha256 `ae5418448a956f4d926c38557e9228b350f93a71b85ac717049fb0aa8438a19e`) and
`dist/Liftosaur.prg.sha256` are refreshed from this session's build and ready to hand to the user
for Task 6's device protocol.

---

## Batch 2 — Garmin Connect display: metadata, and the store-only rule (2026-09-18)

**Trigger:** the user recorded a real workout with the Batch 1 build. Hermes pulled the FIT off the
watch over MTP and decoded it: 11 laps, each with `Exercise` (32-byte string), `SetIndex`, `Weight`,
`Reps`, `Amrap`, `Rest`, `PeakG`/`MeanG` (FLOAT), `RepsEst`, `Samples` (25/s at 25 Hz), session
`SetsDone`/`Volume`/`AccelRate`. **The recording worked. Garmin Connect still showed only name + time.**

| Item | Status | Evidence |
|---|---|---|
| A. Declare the fields in `resources/fitfields.xml` | DONE | all 16 fitField ids match `createFitFields()`; build + `check-device-api` clean |
| B. Inspector decodes values + flags missing metadata | DONE | `lap 1 Exercise=Upright Row, Barbell SetIndex=2 Weight=45lb Reps=10 PeakG=1.07G Samples=50`; `--strict-dev-fields` exits 1 on the real file, 0 on the clean baselines |
| C. Document the two causes | DONE (by Hermes) | `docs/05` — see below |
| D. Gates | DONE | pytest 54 passed; build clean; `verify_watch_payload.py` round-trip clean |
| E. Store package for a beta upload | DONE | `dist/Liftosaur.iq` (411,709 bytes, 8 devices, signed with the existing 4096-bit key) |

**Two documented causes of the Garmin Connect gap** (both verified, neither is guesswork):
1. Missing `fitContributions` metadata. Garmin's Activity Recording docs: "Field id *must* match the
   fitField id in resources or your data will not display" — now declared.
2. **A sideloaded app's developer fields are never rendered by Garmin Connect**; it resolves the
   metadata server-side from the store. Garmin forum thread 299371: the same app sideloaded showed
   nothing and appeared once uploaded as a **beta** app. Hence the `.iq` export: a private beta upload
   is the only route, and that upload is the user's to make (his account).

**Fixed in this batch (Hermes, after Claude was cut off by its session limit):**
- `recountLogged()` in `Workout.mc` — `SetsDone` was restored from storage and incremented from there,
  so the session summary read 16 sets for an 11-set workout. It is now derived from the `_logged` grid.
- `docs/05` sections for both causes + the corrected hardware-confirmation status.

**Measured in that device session, and still open:**
- **No heart rate from any source**: native `heart_rate` 0/12 records, and the app's own per-second
  field never got a reading (`HeartRateAvg` invalid, `Max` 0). Consistent with an 11-second test on a
  watch that was not being worn snugly — an earlier real session the same day had native HR at 100%.
  Needs a worn retest; Garmin's time-in-zones depends on the native stream, not on our field.
- **Auto-exit not yet observed.** The Save path clearly ran (the FIT and the Liftosaur record both
  exist) but nobody watched the screen. Needs the next test to confirm `closing...` then a clean exit.
- The saved file carries `field_description` for only 6 of 16 developer fields (the 10 LAP fields have
  values with no description). `inspect_fit.py --strict-dev-fields` now reports this; worth watching on
  the next recording to see whether it is a per-run writer quirk.
