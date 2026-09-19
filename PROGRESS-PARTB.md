# Progress — heart rate in the app (Part A) + live workout state + attach (Part B)

Session date: 2026-09-19. Continues on-disk in-flight work left by a previous stopped run
(properties.xml/settings.xml runtime backend URL, Comms.mc/Workout.mc/WorkoutUi.mc heart-rate
display) — that work was kept, not reverted, per the task's explicit instruction.

## Part A — heart rate in the app

STATUS: already substantially implemented on disk at session start; verified, not rewritten.

The in-flight diff (`git diff` at session start) already had: `WorkoutController.hrTick()` writing
`_hrLast`/`_hrSum`/`_hrCount`/`_hrMax` with an honest `null` for "no current reading" (sensor
off/unworn/bad value), `currentHrText()`/`avgHrText()`/`maxHrText()`/`hrLiveText()` all returning
`"--"` when absent, live bpm+avg drawn on the working `SetView` screen (`WorkoutUi.mc`, updated via
`WatchUi.requestUpdate()` added to `hrTick()`), avg/max drawn on the DONE summary, and avg/max/live
text drawn on `ExerciseInfoView`/`ExerciseHistoryView`/`ExerciseStatsView`. The existing FIT
developer fields (`HeartRate`/`HeartRateAvg`/`HeartRateMax`, ids 20/21/22, `Workout.mc:433-441`)
were not touched — `hrTick()` still writes `_fHr.setData(hr)` and the summary fields exactly as
before. I read every changed line, confirmed the null-safety and FIT-field claims hold, and left it
alone. Build: clean (see "Gates" below).

**Not independently verified:** live bpm actually updating on a worn watch, since only
`linux-build.sh` (compile) is available in this environment — no simulator run, no hardware. This
matches the existing project convention (Monkey C UI is never verified off-device here).

## Part B — the synced record must be a LIVE workout, and the app must attach to one

### 1. Diagnosis (done BEFORE any change, per the task's instruction)

The user's own framing — "the record arrives as a COMPLETED workout when it should be in
progress" — has one specific, verifiable cause, and it is **not** fixable from this repo alone:

- `backend/python/app/watch_api.py`'s `to_liftohistory()` (pre-session, line ~103) always emitted a
  `duration:` field, and both write paths (`watch_workout()` line 270, `watch_workout_live()` line
  ~392) call the MCP tools `create_history_record`/`update_history_record` with nothing but a
  Liftohistory `text` string.
- Those tools (`lambda/mcp/tools.ts:189-214` in the upstream `docker-liftosaur/liftosaur` clone)
  accept **only** `{text}` / `{id, text}` — no endTime argument exists in the schema.
- The write path (`lambda/mcp/executor.ts:200-204` → `ApiV1_createHistory`/`ApiV1_updateHistory`,
  `lambda/utils/apiv1.ts:161,243`) calls `LiftohistoryDeserializer_deserialize(text, settings)`
  directly and stores whatever it returns, with no post-processing.
- That deserializer (`src/liftohistory/liftohistoryDeserializer.ts:213-214`) computes
  `const endTime = startTime + (durationSec ?? 0) * 1000;` **unconditionally** — there is no
  metadata key, no branch, and no way to leave it `undefined`. Even a `text` with no `duration:`
  field at all still produces `endTime = startTime` (a real, defined number).
- Upstream's actual "in progress" signal is a completely different piece of state:
  `storage.progress`, read via `engine.getProgress(storageJson:)` in
  `ios/LiftosaurWatch/Engine/WorkoutManager.swift:250-254` (confirmed by tracing
  `loadActiveWorkout()` → `currentActiveWorkoutState()` at line 338). None of the 41 MCP tools
  enumerated in `tools.ts` (verified by listing every `name: "..."` in the file) touch
  `storage.progress` — there is no tool that reads or writes it.

**Conclusion, reported before writing any fix:** literal "no endTime" is not achievable through the
MCP/API surface this backend has. This is a hard boundary of the tool contract, not a bug in this
repo's code. I did not guess around this or silently drop the requirement — see below for what was
actually built instead, and why it is the closest available approximation.

### 2. What was implemented (`backend/python/app/watch_api.py`)

A large module docstring now states the above finding with file:line citations, for the next person
who touches this code.

- `LIVE_NOTE` constant + `to_liftohistory(..., live: bool)`: when `live=True`, prepends
  `// Synced live from Garmin watch — workout in progress.` as the record's `notes` (verified this
  round-trips: `liftohistorySerializer.ts:17-22,42-44` serializes `record.notes` as leading `//`
  comment lines with no indent; `liftohistoryDeserializer.ts:189-230`'s `collectWorkoutNotes` reads
  them back as `record.notes` on the next `get_history`/`get_history_record`). This is real,
  user-visible text in the Liftosaur app — not a hidden hack — and doubles as the only signal this
  backend has for "still going."
- `watch_workout_live()` gained a `finished: int = 0` query param. `finished=1` is the **actual
  finish path**: `Comms.mc`'s `postWorkout()` now posts to `/watch/workout/live` with `&finished=1`
  (it already reused this endpoint before this session, via `_recordForSave()` — finish was never a
  separate `create_history_record` call). `finished=1` passes `live=False` into `to_liftohistory()`,
  dropping the marker — the only "done" signal this API can produce.
- `duration:` in the text was already the watch's live elapsed time on every push (confirmed by
  reading `Workout.mc`'s `buildWorkoutBody()`: `:duration_s => elapsedMs() / 1000`, recomputed fresh
  on every call) — so `endTime` was already creeping forward with each update rather than jumping to
  a fixed "final" value. No change needed there; documented as already the best available proxy.
- `parse_liftohistory_record(text)` — a scoped reverse parser (not a general Liftohistory parser: it
  only has to survive round-tripping text this backend itself generated) extracting date, program,
  dayName/week/dayInWeek (with a `/ day: N` single-week fallback), duration, the LIVE_NOTE marker,
  and a flat, order-preserved list of `LoggedSet`s (`_expand_sets`, the inverse of
  `_sets_notation`, AMRAP-aware). `_parse_liftohistory_date` handles both our own ISO stamp and
  Liftosaur's own serializer date format.
- `GET /watch/workout/active` — the attach lookup. Calls `get_history` (limit 20), keeps only
  records still carrying `LIVE_NOTE`, then applies the task's safety rules:
  - no same-day live record → `{"active": false, "stale_ids": [...]}`, never attaches to a previous
    day silently;
  - more than one same-day live record → attaches to the highest record id (ids are
    startTime-derived, so highest = latest start), returns the rest as `extra_live_ids` without
    touching them;
  - on attach, seeds `_LIVE_SET_COUNTS[chosen_id] = len(chosen sets)` so the **pre-existing**
    never-shrink guard in `watch_workout_live()` protects a record this backend process never
    created — this is the concrete mechanism behind "must not shrink a record that already has
    sets."
  - Response also carries `id`, `program`, `day`, `week`, `day_in_week`, `duration_s`,
    `started_at` (unix seconds, parsed from the record's own date), and `sets` for the watch to
    adopt.

### 3. Tests (`backend/python/tests/test_watch_api.py`)

11 new tests, all passing alongside the untouched 65 (one pre-existing test,
`test_live_timestamp_is_stable_across_updates`, needed a one-line update — it read
`splitlines()[0]` for the date header, which is now the LIVE_NOTE marker line; updated to
`splitlines()[1]`, not weakened):
- `test_live_post_defaults_to_marking_the_record_live` / `test_finished_post_drops_the_live_marker`
- `test_parse_liftohistory_record_round_trips_our_own_format` /
  `..._reads_amrap_and_multiple_exercises`
- `test_active_endpoint_reports_no_active_workout`
- `test_active_endpoint_ignores_a_finished_record_without_the_marker`
- `test_active_endpoint_attaches_to_a_same_day_live_record`
- `test_active_endpoint_never_silently_attaches_to_a_stale_previous_day_record`
- `test_active_endpoint_with_two_live_records_attaches_to_the_most_recent`
- `test_attaching_seeds_the_never_shrink_guard_so_the_record_cannot_be_shrunk`
  (the core no-duplicate/no-shrink property)
- `test_attaching_then_a_full_length_update_still_succeeds` (guard doesn't over-trigger)

**Mutation proof (as required — break the guard, confirm the test fails, restore from a /tmp
copy, never `git checkout --`):**
```
cp app/watch_api.py /tmp/watch_api.py.orig-backup
```
1. Disabled the stale-day filter (`same_day = [(rid, p) for rid, p in live]`) →
   `test_active_endpoint_never_silently_attaches_to_a_stale_previous_day_record` FAILED
   (`assert True is False` — it attached to yesterday's record).
2. Disabled `_LIVE_SET_COUNTS[chosen_id] = len(chosen["sets"])` seeding →
   `test_attaching_seeds_the_never_shrink_guard_so_the_record_cannot_be_shrunk` FAILED — the
   1-set stale payload was NOT rejected, i.e. it would have shrunk a 3-set record to 1.
3. Made `watch_workout_live` ignore `finished` (`live=True` unconditionally) →
   `test_finished_post_drops_the_live_marker` FAILED — the marker survived the finish POST,
   i.e. the record would stay "live" forever.

Each mutation was restored via `cp /tmp/watch_api.py.orig-backup app/watch_api.py`, confirmed
byte-identical with `diff` before re-running the full suite (76 passed each time after restore).

### 4. Watch side (`embedded/monkeyc`)

- `Comms.mc`: `fetchActiveWorkout()` (GET `/watch/workout/active`) + `onActiveWorkoutResponse()`,
  called from `app.mc`'s `onStart()` alongside the existing `fetchPrograms()`/`retryPending()`.
  Stores the parsed attach payload via `_controller.setActiveAttach(...)`; logs (never blocks) any
  `extra_live_ids`/`stale_ids`. `postWorkout()`'s URL gained `&finished=1`.
- `Workout.mc`: `_activeAttach` field + `setActiveAttach()`. `startWorkout()` now calls
  `_applyActiveAttach()` right after `_resetEditable()`. That method:
  - only applies on an **exact** program-name AND day-name match against what was just started
    (anything else is left alone — deliberately conservative, matching "no active workout older
    than today" in spirit for the "wrong day" case too);
  - consumes `_activeAttach` (sets it to `null`) unconditionally, so a later re-selected day can
    never re-import a session that was already applied or belongs elsewhere;
  - matches each returned set to a plan exercise by name, fills `_logged`/`_weights`/`_reps` in
    order per exercise (skipping overflow if the real record has more sets for an exercise than the
    local plan has slots for — cannot be represented in the fixed grid, documented rather than
    silently mis-assigned), then `recountLogged()` (existing single-source-of-truth counter);
  - repositions `_exIndex`/`_setIndex` to the first not-yet-logged slot;
  - writes `Application.Storage.setValue("lift_live_record", id)` directly (the literal key string,
    matching the existing convention documented in `Comms.mc`'s own comment — `clearSaved()` uses
    the same literal rather than importing Comms.mc's const);
  - sets `_startedAt` to the attach's `started_at` (same units this codebase already sends over the
    wire as `started_at` — documented in `docs/06-sync.md` as unix seconds) so `elapsedMs()`
    correctly measures from the workout's real start, not from the moment this watch attached.

**Not verified beyond compilation.** This is the one part of today's session with no test harness
at all — Monkey C cannot run outside the device/simulator, and this environment has neither. The
backend behavior it depends on (`/watch/workout/active`'s shape, the never-shrink seeding) is
fully covered by the pytest suite above; the watch-side consumption of that response — the
exercise-name matching, the grid population, the cursor repositioning — is unverified beyond "it
compiles and references the correct field names." **This needs the physical watch**, specifically:
start a workout in the Liftosaur phone app, log a couple of sets there, then open the watch app on
the same day/program and confirm it lands on the right exercise/set with those sets already shown
as logged (not re-prompted), and that Liftosaur still shows one record afterward, not two.

### 5. Gates run this session

Backend:
```
cd backend/python && ./.venv/bin/python -m pytest -q
```
Result: `76 passed` (baseline 65 + 11 new), both before touching watch-side code and again after.

Build:
```
cd embedded/monkeyc && HOME=/home/hermes tools/linux-build.sh venu2s
```
Result: `BUILD SUCCESSFUL`, `bin/Liftosaur.prg (239980 bytes)`,
`check-device-api: all 77 module calls exist on 'venu2s'`. Warnings are the same pre-existing
"Cannot determine if container access is using container type" / one unused-member-variable class
of warning present before this session (confirmed by diffing the warning list against the very
first build run this session, before any edits) — no new warning categories introduced.

Artifact:
```
cp embedded/monkeyc/bin/Liftosaur.prg dist/Liftosaur.prg
sha256sum dist/Liftosaur.prg > dist/Liftosaur.prg.sha256   # (as "<hash>  Liftosaur.prg")
```
`dist/Liftosaur.prg.sha256`: `bc107178ea75b9f2ec7629c87e8de5a56de631ee9eb5aa55dc021bb2296af12a  Liftosaur.prg`
— verified with `sha256sum -c` (`Liftosaur.prg: OK`).

### 6. Known limitations, stated plainly

- "No endTime" is not literally achieved — cannot be, through this MCP surface (section 1). The
  LIVE_NOTE marker is the closest available substitute and is the mechanism `/watch/workout/active`
  depends on.
- Staleness ("today" vs "a previous day") compares UTC date strings, matching this codebase's
  existing UTC convention elsewhere — not the user's actual local calendar day.
- `parse_liftohistory_record` is intentionally not a general Liftohistory parser; it is scoped to
  text this backend itself produces (single-week-or-multiweek forms it writes, lb/kg, no warmup
  sets). A record with warmup sets or hand-edited notes from the Liftosaur app itself is not
  something `/watch/workout/active` needs to parse, since only backend-authored LIVE-marked records
  are ever candidates.
- Watch-side grid adoption (section 4) is unverified on hardware, as stated above.
