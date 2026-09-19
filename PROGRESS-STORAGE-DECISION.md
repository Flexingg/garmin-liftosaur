# Progress — the storage/live-workout decision, and the heart-rate fix

Session date: 2026-09-19. Follows on from PROGRESS-PARTB.md (which built the attach-on-launch
feature this session removes) and PROGRESS-FIT.md (which first tried to fix heart rate).

## Job 1 — Can Liftosaur's synced STORAGE carry a live workout? VERDICT: NO

**Headline: not viable through this backend's access. Confirmed two independent ways.**

1. **Upstream, from `docker-liftosaur/liftosaur` (read-only research, not modified):**
   In-progress workouts ARE part of synced storage — `storage.progress: IHistoryRecord[]`
   (`src/types.ts:1877`), the same record shape as finished history, told apart by having no
   `endTime` (`src/types.ts:977`). The client reads it as `state.storage.progress?.[0]`
   (`src/models/progress.ts:839,852`). But it syncs over a **different, heavier-weight channel**
   than anything this project uses: `POST /api/sync2` (`lambda/index.ts:552`), authenticated by a
   **session cookie** (`getCurrentUserIdFromCookie`, `lambda/index.ts:279`) — not the API key our
   backend holds — carrying a versioned diff merged field-by-field
   (`CONTROLLED_FIELDS.progress`, `src/types.ts:1985-2001`; `userDao.applySafeSync2`,
   `lambda/dao/userDao.ts:241-291`).

2. **Our own backend's access, confirmed by reading `backend/python/app/plan.py` and every MCP
   tool this project can call:** the only credential is `LIFTOSAUR_API_KEY`
   (`plan_mod.api_key()`), used solely as a Bearer token against `https://www.liftosaur.com/mcp`.
   None of the 41 MCP tools (verified by listing every `create_history_record`-style tool
   available) touch `storage.progress` — only finished-shaped history records
   (`create_history_record`/`update_history_record`/`delete_history_record`/`get_history`). The
   `LiftohistoryDeserializer_deserialize` that backs those tools **unconditionally** computes
   `endTime = startTime + (durationSec ?? 0) * 1000` (`liftohistoryDeserializer.ts:213-214`) — a
   record posted through this API can never come out the other side without an `endTime`, full
   stop.

3. **Empirical, read-only, against the real account** (`mcp_call("get_history", {"limit": "5"})`
   via the backend's own credentialed path): the account's 5 most recent records all come back
   fully formed and "finished"-shaped, including the watch's own live-synced record
   (id `1789801063000`, now showing its final 3-exercise, 6622s form). Nothing in the 41-tool
   surface ever exposed it, or anything else, as "in progress" while it was still going. This
   matches, and resolves, the earlier real-device finding that the live record did not appear in
   `get_history` "at all" mid-workout — it wasn't a bug in our write path, it's that the
   history-record surface these tools use is not the same channel a "live" workout would need.

**Conclusion:** to make a workout show as in-progress in the phone app would require
`/api/sync2` with the user's actual logged-in session — a materially different, heavier
credential than the API key this project has ever used, and out of scope to go obtain. Not
pursued.

### What was done about it

- **Kept:** the per-set live sync (`POST /watch/workout/live`, `Comms.postLiveSet()`) — creating
  a record on the first completed set and updating it on every later one. This is useful in its
  own right (a watch crash or dead battery mid-session no longer loses the workout) independent of
  whether the phone can ever show it as "in progress," and was an explicit prior decision
  (PROGRESS-LIVE.md, "do not re-litigate"). Also kept: the `LIVE_NOTE` marker
  (`"Synced live from Garmin watch — workout in progress."`) in the record's notes while syncing —
  harmless, honest, user-visible text.
- **Removed, not just disabled** (per the task's instruction — dead code left running is worse
  than no code): the attach-on-launch feature, since real-device testing had already shown it does
  not work (a workout open in the phone app is not discoverable through the history API at all —
  there was never anything for it to find, for the goal it was built for).
  - Backend (`backend/python/app/watch_api.py`): `GET /watch/workout/active`,
    `parse_liftohistory_record()`, `_expand_sets()`, `_parse_liftohistory_date()`,
    `_AMRAP_SET_RE` — all deleted (the parser had no other caller). Module docstring rewritten
    with the full verdict and citations above, for the next person who touches this file.
  - Watch (`embedded/monkeyc/source/`): `Workout.mc`'s `_activeAttach` field,
    `setActiveAttach()`, `_applyActiveAttach()` (and its call from `startWorkout()`); `Comms.mc`'s
    `fetchActiveWorkout()`/`onActiveWorkoutResponse()`; `app.mc`'s `onStart()` call site. All
    deleted, not commented out.
  - Tests (`backend/python/tests/test_watch_api.py`): the 9 attach-only tests removed
    (`test_parse_liftohistory_record_*`, `test_active_endpoint_*`, `test_attaching_*`). The 2
    tests that cover the LIVE_NOTE marker itself (`test_live_post_defaults_to_marking_the_record_live`,
    `test_finished_post_drops_the_live_marker`) were kept — that behavior didn't change.

```
cd backend/python && ./.venv/bin/python -m pytest -q
```
Result: `67 passed` (76 baseline − 9 removed = 67; nothing else touched or weakened).

---

## Job 2 — Heart rate (the actual, verified fix)

**The bug as it existed in the last commit (466b07c) was not the "enableSensorType inside the
event handler" chicken-and-egg described in the task brief** — that had already been fixed in an
earlier session (`startHrCapture()` already called `Sensor.enableSensorType` /
`Sensor.enableSensorEvents` correctly at session start, not inside `onSensorEvent`). Real-device
testing after that fix still showed heart rate reading null, which is why the investigation
continued here rather than re-applying an already-applied fix.

**Root cause, per the Connect IQ SDK docs (`~/.Garmin/ConnectIQ/Sdks/.../doc/Toybox/`, read
locally, not guessed):** `Sensor.getInfo()` — the API `hrTick()` was polling — is the *raw* sensor
handle. This project starts an `ActivityRecording.Session` for every workout
(`Workout.mc:380-398`), and Garmin's documented pattern for reading the *current* value of a
sensor already feeding an active recording session is `Activity.getActivityInfo().currentHeartRate`
(`Toybox/Activity/Info.html`), not `Sensor.getInfo()` — the same reason the SDK docs state
`Sensor.getInfo()`/`enableSensorType()` "will cause an app crash if called from a data field app"
(data fields run inside an active recording and are steered to `Activity.Info` instead). This
matches the exact symptom reported: the watch's own face showed live HR (i.e. the system's HR
provider was working) while this app's raw `Sensor.getInfo().heartRate` read null the whole
session.

**Fix — `embedded/monkeyc/source/Workout.mc:627-651`, `hrTick()`:** now reads
`Activity.getActivityInfo().currentHeartRate` first; only if that comes back null does it fall
back to the pre-existing `Sensor.getInfo().heartRate` path (kept as a defensive fallback, e.g. for
the case where `_session` failed to start — though `hrTick()` currently only ever runs once a
session exists). `startHrCapture()`'s `Sensor.enableSensorType`/`enableSensorEvents` calls were
left in place unchanged — harmless, and still needed for the fallback path. The
0–250bpm sanity bound and the "null means no current reading, never 0, never a stale value" rule
(`_hrLast = hr`, `currentHrText()` returns `"--"`) were both already correct and untouched.

**Already-working UI surfacing (unchanged, verified present before touching anything):**
`currentHrText()`/`avgHrText()`/`maxHrText()` on the working set screen, the DONE summary, and
`ExerciseInfoView`/`ExerciseHistoryView`/`ExerciseStatsView` (`WorkoutUi.mc:308-857`); FIT
developer fields `HeartRate`/`HeartRateAvg`/`HeartRateMax` (ids 20/21/22) written from the same
`hrTick()`/`writeSessionSummaryFields()` this session touched.

**What cannot be verified off-device, stated plainly:** whether `Activity.getActivityInfo()`
actually returns a non-null `currentHeartRate` on this specific venu2s while a Liftosaur session is
recording. Monkey C has no unit-test harness and this environment has neither a simulator nor the
physical watch — `linux-build.sh` proves it compiles and every symbol exists on `venu2s`, nothing
more. **This needs the physical watch**: start a workout, confirm a live bpm number appears on the
set screen (not "--"), and check the finished FIT file's native `heart_rate` stream plus the
`HeartRateAvg`/`HeartRateMax` developer fields with `inspect_fit.py`.

There is no backend/payload component to heart rate at all (it is never sent to the backend — only
written locally to the FIT file), so there is nothing to add a backend test for, per the task's own
"wherever the code allows it" carve-out. No new backend guard was added this session (Job 1 only
removed code), so there is no new mutation-test obligation beyond the existing 67-test suite, which
still passes unchanged.

```
cd embedded/monkeyc && HOME=/home/hermes tools/linux-build.sh venu2s
```
Result: `BUILD SUCCESSFUL`, `bin/Liftosaur.prg (236860 bytes)`, `check-device-api: all 78 module
calls exist on 'venu2s'`. Warnings are the same pre-existing "Cannot determine if container access
is using container type" class throughout `Workout.mc`/`WorkoutUi.mc`, plus one
"Statement is not reachable" at `Workout.mc:387` — **confirmed pre-existing**, not introduced this
session: built the pre-session commit (466b07c) in an isolated `git worktree`, found the identical
warning at its then-line-404 (same statement, shifted by this session's edits), then removed the
worktree. One pre-existing unused-member-variable warning (`WorkoutUi.mc:891`, `InfoDelegate._c`)
also untouched.

---

## Deliverable

```
cp embedded/monkeyc/bin/Liftosaur.prg dist/Liftosaur.prg
cd dist && sha256sum Liftosaur.prg > Liftosaur.prg.sha256
sha256sum -c Liftosaur.prg.sha256   # -> Liftosaur.prg: OK
```
New digest `4b111265f73f7ec7535719f95e62700d311589f50bcce59a542f6333df4fcafa` (old was
`bc107178ea75b9f2ec7629c87e8de5a56de631ee9eb5aa55dc021bb2296af12a` — confirmed different before
overwriting, so this is genuinely this session's build, not a stale copy).

**Sideload:** watch → Settings → System → USB Mode → MTP, copy `dist/Liftosaur.prg` to
`GARMIN/APPS`, then **physically unplug** (that's when it installs).
