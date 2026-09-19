# Watch: real exercises/weights/reps + HR + accelerometer in the Garmin activity, and auto-exit

> **For the implementing agent (Claude Code).** Repo: `/home/hermes/repos/garmin-liftosaur`.
> The previous batch is committed at `cb54f2d` — work from a clean tree, keep `PROGRESS-FIT.md` at the
> repo root (create it FIRST, update it after every task, one line per task with the command + observed
> result). Hermes re-runs every gate and reads the diff; your summary is not evidence.

**Goal:** when the user finishes a workout, the Garmin activity should carry the real per-set
exercise/weight/reps, heart rate throughout, and accelerometer-derived per-set metrics; and the app
should close itself after Save/Discard.

**Watch:** Garmin Venu 2S (`venu2s`, part `006-B3704-00`), Connect IQ device API 5.0, SDK 9.2.0.
Build: `cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s`.

---

## 1. Capability audit — ALREADY DONE, do not re-derive (and do not promise more than this)

Verified by Hermes against `~/.Garmin/ConnectIQ/Devices/venu2s/venu2s.api.debug.xml` (the device's own
API file, the same one `tools/check-device-api.py` trusts). Presence means the symbol is in the file.

**PRESENT on this watch — this is what we build with**

| API | Why it matters |
|---|---|
| `ActivityRecording.Session.createField(name, fieldId, type, options)` | writes **FIT developer fields**: "can be displayed in Garmin Connect as a per-second graph, as lap information, or as workout summary information" |
| `options :mesgType` = `FitContributor.MESG_TYPE_RECORD` / `_LAP` / `_SESSION` | per-second vs per-set vs summary placement |
| `FitContributor.DATA_TYPE_*` (`UINT8/16/32`, `SINT*`, `FLOAT`, `DOUBLE`, `STRING`) | field types. **Strings are allowed on LAP and SESSION, forbidden on RECORD** |
| `FitContributor.Field.setData(input)` | write a value |
| `Session.addLap()` | already used; makes one FIT lap per set (timing only today) |
| `Session.setTimerEventListener(listener)` | 1 Hz callbacks tied to the recording |
| `Sensor.registerSensorDataListener(listener, options)` | high-rate accel: `:period` ≤ 4 s, `:accelerometer => {:enabled, :sampleRate, :includePower, :includePitch, :includeRoll}` |
| `Sensor.getMaxSampleRateForSensorType(:accelerometer)`, `Sensor.getMaxSampleRate()` | rate negotiation |
| `Sensor.enableSensorType` / `setEnabledSensors` / `enableSensorEvents` (1 Hz) | turning the onboard sensors on for this app |
| `Sensor.Info.heartRate` (bpm), `.accel` (milli-G array) | the readings |
| `Sensor.SensorData.accelerometerData.x/.y/.z` | accel Arrays in **milli-G** (1000 = 1 G) |

**ABSENT on this watch — these are impossible, so do not attempt them and do not claim them**

| Missing | Consequence |
|---|---|
| `Session.addSets` / `createSet` / `SetType` | no *native* Garmin strength sets with reps/weight; laps + developer fields are the only route |
| `Session.addInformation` | cannot inject samples into the metrics stream |
| `SensorLogging.enableSensorLogging` | **cannot write a raw sensor stream (HR or accelerometer) into the FIT file** |

**Therefore:** raw accelerometer *cannot* live in the FIT. The achievable accelerometer story is
(a) per-set derived metrics written as lap developer fields, and optionally (b) streaming raw samples to
our own backend, which already has the physics/rep-detection pipeline (`POST /api/v1/sets`, docs/02).

## 2. Measured baseline — real FIT files pulled from the user's watch today

Hermes copied four activities over MTP and decoded them with
`embedded/monkeyc/tools/inspect_fit.py` (written and verified by Hermes against these files; extend it,
don't rewrite it from scratch):

```
2026-09-18-03-21-46.fit  records=40   native HR 100% (51-81 bpm)  time_in_zone=15  laps=16  dev fields=0
2026-09-18-05-47-03.fit  records=42   native HR   0%               time_in_zone=0   laps=18  dev fields=0
2026-09-18-04-00-52.fit  records=4278  native HR 100% (37-115)     time_in_zone=23  laps=0   dev fields=0
2026-09-17-03-57-50.fit  records=3872  native HR 100% (54-121)     time_in_zone=21  laps=0   dev fields=0
```

Conclusions that shape the work:
1. **Developer fields do not exist yet anywhere** — the per-set exercise/weight/reps data is a real gap.
2. **Laps already exist** on app-recorded sessions (16-18 per test) but carry only timing, so Garmin
   Connect shows anonymous laps.
3. **Native HR is intermittent**: present at 100% in some app-recorded sessions, completely absent in
   others (a 42 s session had none). HR *can* be recorded for a CIQ session, so the job is to make it
   reliable (explicitly enable the onboard HR sensor) **and** guarantee data with our own field.

## 3. Ground rules

- Do not weaken/skip/delete an existing test assertion. If one is genuinely wrong, quote it, explain,
  leave it failing, and say so.
- Never post to `/api/v1/watch/workout` without `dry_run=1` unless the task explicitly says live; never
  write into the user's real Liftosaur history for testing.
- Do not touch the parked BLE files (`LiftBleTransport.mc`, `LiftFrame.mc`, `LiftBinary.mc`,
  `LiftDelegate.mc`, `Transport.mc`) or `docs/04` — `RecordingController.mc`/`SampleBuffer.mc` may be
  read for reference, and only Task 5 may touch them.
- ASCII-only strings in Monkey C (`\uXXXX` prints literally on this platform).
- Everything added to the recording must be **failure-proof**: a developer field that fails to create,
  a sensor that refuses to register, or a null reading must never break a workout or block a save.
  Every write is guarded; every setup call is inside `try`/`catch` or a `Toybox has :X` check.
- `git commit` freely; **never `git push`**. No `git checkout -- <file>` on uncommitted work; back a
  file up to `/tmp` before any mutation test and restore from the copy.

---

## Task 1 — Auto-exit after Save/Discard (user request #1)

**Files:** `embedded/monkeyc/source/Workout.mc`, `Comms.mc`, `WorkoutUi.mc`

Design (pending the user's answer to "exit timing" — default A):

- **A (default):** after Save, the DONE screen stays until the Liftosaur upload resolves, then the app
  closes itself; a watchdog exits after 8 s regardless so the app can never hang on the network.
- On Discard: close immediately once `session.discard()` returns.

```monkeyc
    // ---- exit after finish (Task 1) ----
    private var _exitPending;      // finish resolved; waiting for the upload (or the watchdog)
    private var _exitTimer;        // one-shot watchdog

    function finishExit() as Void {
        // Called by the upload callback (success or failure) and by the watchdog.
        if (!_exitPending) { return; }
        _exitPending = false;
        if (_exitTimer != null) { _exitTimer.stop(); _exitTimer = null; }
        stopRest();
        if (Toybox has :Sensor) {
            try { Sensor.unregisterSensorDataListener(); } catch (e) { }
        }
        System.println("Workout: exiting after finish");
        System.exit();
    }

    function requestExit() as Void {
        if (_exitPending) { return; }
        _exitPending = true;
        if (!_started) {
            // discard path: nothing to wait for
            finishExit();
            return;
        }
        _exitTimer = new Timer.Timer();
        _exitTimer.start(method(:finishExit), 8000, false);
    }
```

- `resolveSave(save)`: on discard call `requestExit()` at the end; on save call `requestExit()` too —
  the upload callback will finish it early.
- `LiftComms.onPostResponse()`: in **both** branches (success and stashed-failure) call
  `_controller.finishExit();` — but only when an exit is pending, so a background retry at app start
  does not close the app.
- `SetView.onUpdate()`: when `_c.exitPending()` show `closing...` under the result lines so the user
  knows the app is about to close. Add `function exitPending() as Boolean { return _exitPending; }`.
- While `_exitPending`, `SetDelegate`/`SetMenuDelegate` inputs that could re-resolve the workout must be
  no-ops (`finishWorkout()`, `resolveSave()`; the latter already guards on `!_started`).

## Task 2 — Per-set exercise / weight / reps as FIT developer fields (user request #2, the core ask)

**File:** `embedded/monkeyc/source/Workout.mc` (import `Toybox.FitContributor`)

Create the fields once, right after `_session.start()` in `startWorkout()`. Field ids are ours to
choose (0..N) and must be stable (they identify the field to Garmin Connect).

```monkeyc
    private var _fExercise;   // LAP, STRING  - exercise name
    private var _fSetIndex;   // LAP, UINT8   - 1-based within the exercise
    private var _fWeightLb;   // LAP, UINT16  - lb
    private var _fReps;       // LAP, UINT8   - reps performed
    private var _fAmrap;      // LAP, UINT8   - 1 = AMRAP set
    private var _fRestS;      // LAP, UINT16  - prescribed rest
    private var _fSetsDone;   // SESSION, UINT8
    private var _fVolumeLb;   // SESSION, UINT32

    private function createFitFields() as Void {
        if (_session == null or !(Toybox has :FitContributor)) { return; }
        try {
            _fExercise = _session.createField("Exercise", 0, FitContributor.DATA_TYPE_STRING,
                {:mesgType => FitContributor.MESG_TYPE_LAP, :count => 32});
            _fSetIndex = _session.createField("SetIndex", 1, FitContributor.DATA_TYPE_UINT8,
                {:mesgType => FitContributor.MESG_TYPE_LAP});
            _fWeightLb = _session.createField("Weight", 2, FitContributor.DATA_TYPE_UINT16,
                {:mesgType => FitContributor.MESG_TYPE_LAP, :units => "lb"});
            _fReps = _session.createField("Reps", 3, FitContributor.DATA_TYPE_UINT8,
                {:mesgType => FitContributor.MESG_TYPE_LAP});
            _fAmrap = _session.createField("Amrap", 4, FitContributor.DATA_TYPE_UINT8,
                {:mesgType => FitContributor.MESG_TYPE_LAP});
            _fRestS = _session.createField("Rest", 5, FitContributor.DATA_TYPE_UINT16,
                {:mesgType => FitContributor.MESG_TYPE_LAP, :units => "s"});
            _fSetsDone = _session.createField("SetsDone", 10, FitContributor.DATA_TYPE_UINT8,
                {:mesgType => FitContributor.MESG_TYPE_SESSION});
            _fVolumeLb = _session.createField("Volume", 11, FitContributor.DATA_TYPE_UINT32,
                {:mesgType => FitContributor.MESG_TYPE_SESSION, :units => "lb"});
        } catch (e) {
            // Developer fields are a bonus. Never let them cost a workout.
            _fitNote = "dev fields unavailable";
        }
    }
```

Then, immediately **before** the existing `_session.addLap()` in `markLap()`, write the current set's
values (the LAP message is emitted at `addLap()` with the values held at that moment - so set all of
them each time; a stale value leaking into the next lap is the likely bug):

```monkeyc
    // One FIT lap per completed set, carrying what the set actually was. Values must
    // be written IMMEDIATELY before addLap(): the lap message snapshots them.
    private function setLapFields() as Void {
        if (_session == null) { return; }
        try {
            if (_fExercise != null) { _fExercise.setData(currentExerciseName()); }
            if (_fSetIndex != null) { _fSetIndex.setData(_setIndex + 1); }
            if (_fWeightLb != null) { _fWeightLb.setData(_weights[_exIndex][_setIndex] as Number); }
            if (_fReps != null) { _fReps.setData(_reps[_exIndex][_setIndex] as Number); }
            if (_fAmrap != null) { _fAmrap.setData(currentAmrap() ? 1 : 0); }
            if (_fRestS != null) { _fRestS.setData(currentRest()); }
        } catch (e) {
            _fitNote = "lap field write failed";
        }
    }
```

- Note `currentExerciseName()` already returns "" past the last exercise (previous batch) — call
  `setLapFields()` **before** the cursor advances. Read `completeSet()` carefully: capture the values
  for the set being logged *before* `_setIndex++`/`_exIndex++`, then `markLap()`.
- Session-level summary: write `_fSetsDone` and `_fVolumeLb` (sum of weight x reps over logged sets)
  just before `_session.save()` in `resolveSave()`, wrapped in `try`/`catch`.
- Also make the activity name carry the week: `"Liftosaur - " + dayName(_dayIndex) + " (" + _section + ")"`.
- **Verification is Task 6** (FIT inspection), not a unit test — Monkey C cannot be run off-device.

## Task 3 — Heart rate throughout, and zones (user request #3)

**File:** `embedded/monkeyc/source/Workout.mc`

1. **Enable the onboard HR sensor explicitly** before creating the session, so HR is recorded
   reliably (the baseline shows it is intermittent: 100% in some app sessions, 0% in others):
   `Sensor.enableSensorType(Sensor.SENSOR_ONBOARD_HEARTRATE)` inside `try`/`catch` (symbol verified
   present), plus `Sensor.enableSensorEvents(method(:onSensorEvent))` so the OS knows the app wants
   sensor data. Do not call `setEnabledSensors([...])` — that would disable the user's other sensors.
2. **Guarantee the data with our own field:** a 1 Hz timer (the app already runs a 1 Hz rest timer;
   add a separate one) that reads `Sensor.getInfo().heartRate` and writes it to
   `_fHr` = `createField("HeartRate", 20, FitContributor.DATA_TYPE_UINT8, {:mesgType => MESG_TYPE_RECORD, :units => "bpm"})`.
   Records are the only place a per-second graph comes from, and this works even if the native stream
   is missing. Track min/avg/max in the controller for two SESSION fields (`HeartRateAvg`,
   `HeartRateMax`, ids 21/22) so the summary always shows HR.
3. Stop the HR timer in `resolveSave()` and unregister the sensor listener in `finishExit()`.
4. **Honest limitation to document in `docs/05`:** Garmin Connect computes *time in zones* from the
   device's **native** `heart_rate` records (`time_in_zone`/`hr_zone` messages). Our developer field is
   a chart plus summary, not a zone source. Because the baseline proves native HR *is* recorded in some
   sessions, step 1 is the actual fix for zones; the verification protocol (Task 6) must state whether
   native HR appeared, so we never claim zones we did not deliver.

## Task 4 — Accelerometer: per-set metrics in the FIT (user request #4a)

**File:** `embedded/monkeyc/source/Workout.mc`

```monkeyc
    // High-rate accelerometer. The public Sensor API caps this well below 100 Hz; ask the
    // system for its maximum and clamp to 25 Hz so the rate matches the contract in docs/01.
    private function startAccel() as Void {
        if (!(Toybox has :Sensor)) { return; }
        try {
            var maxRate = Sensor.getMaxSampleRateForSensorType(:accelerometer);
            var rate = 25;
            if (maxRate != null and maxRate < rate) { rate = maxRate; }
            _accelRate = rate;
            Sensor.registerSensorDataListener(method(:onAccelData),
                {:period => 1, :accelerometer => {:enabled => true, :sampleRate => rate}});
        } catch (e) {
            _fitNote = "accel unavailable";
        }
    }
```

- `onAccelData(data)`: accumulate per set — sample count, sum of magnitude, peak magnitude, and a
  simple **rep estimate** by counting magnitude peaks above a hysteresis band. Reset the accumulators
  when a set is logged (`completeSet()`), because each lap is one set.
- Write the results as LAP developer fields next to Task 2's: `PeakG` (peak magnitude / 1000, FLOAT,
  units "G"), `MeanG` (FLOAT), `RepsEst` (UINT8), `Samples` (UINT16). `_accelRate` also as a SESSION
  field so the sampling rate is visible in the file.
- The user's `Chin Up`/`Plank` sets have weight 0 — do not divide by weight anywhere.
- Stop the listener in `resolveSave()`/`finishExit()` and document battery cost in `docs/05`.

## Task 5 — DELIBERATELY OUT OF SCOPE (user decision, 2026-09-18)

The user was offered the optional raw-accelerometer upload to the backend (the `POST /api/v1/sets`
physics pipeline) and chose **"Garmin activity only — no network, everything stays on the watch"**.
So: **do not** add any accelerometer upload path, do not touch `RecordingController.mc` /
`SampleBuffer.mc`, do not relax `SetIngest.prescribed_weight_lbs`, and do not change
`backend/python/app/main.py`. The accelerometer work is Task 4 alone (per-set derived metrics as FIT
developer fields). Mention the decision in one line in `docs/05` so the next reader knows it was a
choice and not an oversight.

## Task 6 — Prove it on the real device (mandatory)

**Tool:** `embedded/monkeyc/tools/inspect_fit.py` (exists, written and verified by Hermes against the
four files in §2 — extend it, keep it stdlib-only). Add to it:
- print each LAP's developer fields in a stable table (`lap N: Exercise=... Weight=... Reps=...`);
- exit non-zero with a clear message when a `--expect-laps N --expect-dev-fields` check fails, so it can
  be used as a gate;
- flag `native HR present: yes/no` explicitly, since zones depend on it.

**Helper:** `embedded/monkeyc/tools/pull_watch_fits.sh` — copies the newest activity FIT files off the
watch. These MTP commands are verified on this machine (note the **raw space** in the URI; `%20` is
double-encoded and fails with "File not found"):

```bash
gio mount -l | grep -i mtp                      # find the device URI
URI="mtp://091e_4e78_0000c8c4c89c/Internal Storage/GARMIN/Activity"
gio list "$URI"                                  # newest last; MTP listing caps at ~200 entries
gio copy "$URI/<file>.fit" ./fit-out/
```

**Protocol** (write the results into `PROGRESS-FIT.md` — this is the only proof that counts):
1. Build and hand the `.prg` to the user for a **30-second test workout** (2 exercises, 4 sets, nothing
   heavy): start a workout, log the sets, Save & finish.
2. Pull the new `.fit`, run `inspect_fit.py`, and assert, from real output:
   - lap count == sets logged;
   - every lap carries `Exercise`, `Weight`, `Reps`, `SetIndex`;
   - the accel fields are present and plausible (`PeakG` > 1.0 for a moving set);
   - the file has a `HeartRate` developer field with roughly one sample per second, **and** report
     whether native `heart_rate` records appeared (zones);
   - the session summary carries `SetsDone`/`Volume`/`HeartRateAvg`/`HeartRateMax`.
3. Re-run the **whole previous** verification so nothing regressed:
   `cd backend/python && .venv/bin/python -m pytest -q` (baseline **54 passed**),
   `HOME=/home/hermes ./tools/linux-build.sh venu2s`,
   `python3 tools/verify_watch_payload.py` (tunnel + localhost, dry-run only).

## Task 7 — Docs and ship

- `docs/05-watch-workout-app.md`: what the activity now contains, the developer-field table (name, type,
  mesgType, meaning), the three things this device **cannot** do (`addSets`/`SetType`, `addInformation`,
  `enableSensorLogging`) and therefore why raw accelerometer is not in the FIT, the zones caveat, and
  the battery/rate notes.
- Refresh `dist/Liftosaur.prg` + `.sha256` (the sidecar holds the hash; keep the two in sync).
- Finish with `PROGRESS-FIT.md` showing no TODO rows.

---

## Acceptance criteria

1. After Save, the app closes itself once the upload resolves (or within 8 s); after Discard it closes
   immediately. Both paths are observable on the watch.
2. The recorded FIT has one lap per logged set, and every lap carries the exercise name, weight and
   reps — verified by decoding the real file from the watch, not by assertion.
3. HR is present in the recorded activity one way or another (our per-second field at minimum), the
   summary carries avg/max HR, and `PROGRESS-FIT.md` states plainly whether native HR (and therefore
   Garmin's zones) appeared.
4. Accelerometer-derived per-set fields exist in the FIT and are plausible; `docs/05` states the hard
   limit that raw accel cannot be stored in the FIT on this device, and that uploading the raw track was
   a deliberate user choice not to do.
5. The venu2s build passes `check-device-api.py`; backend suite is ≥ 54 passed with nothing removed;
   `dist/` is refreshed.

## Risks

- **Developer fields may not be accepted by the device at runtime** even though the symbols exist. If
  `createField` fails or throws, say so in PROGRESS-FIT.md with the exact error — do not silently ship
  laps without data.
- **Garmin Connect's UI for developer fields is limited** (numeric fields graph; the exercise-name
  string may only be visible in the FIT file and in tools). Do not promise more than the file shows.
- **HR sensor lock** takes a few seconds; the very short test workout may legitimately show no HR in the
  first seconds. Distinguish that from "not recorded at all".
- Writing a RECORD field every second for a 90-minute session adds file size; keep the field set small.
- The accelerometer fields depend on `registerSensorDataListener` actually delivering data while a workout runs; if it does not, report it rather than shipping constant zeros.
