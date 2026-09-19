# Progress — watch save/exit/history plan

Plan: `.hermes/plans/2026-09-18_033318-watch-save-exit-history.md`

Tunnel URL check at start: `~/.liftosaur-tunnel-url` = `https://transcripts-forward-acdbentity-ascii.trycloudflare.com`,
matches `LIFT_BACKEND` in `embedded/monkeyc/source/Comms.mc:28`. OK to build without regenerating plan.

| Task | Status | Notes |
|---|---|---|
| 1. Rewrite urlEncode (422 fix) | DONE | replaced function, see below |
| 2. Dry-run backend + tests + verify_watch_payload.py + mutation proof | DONE | 2a-2d all done |
| 3. Stop stale-pending corruption | DONE | see below |
| 4. Honest workout duration | DONE | see below |
| 5. Kill "done" exercise sentinel | DONE | see below |
| 6. Make the app exitable | DONE | implemented with 2 deliberate deviations, documented below |
| 7. De-clutter exercise history (scrolling list) | DONE | see below |
| 8. Correct week/dayInWeek | DONE | see below |
| 9. Build, test, prove | DONE | see below |
| 10. Ship artifact, update docs | DONE | see below |

---

## Task 1 — Rewrite the percent-encoder

STATUS: DONE

Replaced `Comms.urlEncode()` in `embedded/monkeyc/source/Comms.mc` with the RFC-3986 version from the
plan: builds codepoints from `String.toCharArray()` / `Char.toNumber()`, never `String.toNumber()`.

Command:
```
grep -n "toNumber" embedded/monkeyc/source/Comms.mc
```
Result:
```
53:    // toNumber() parses a number ("5".toNumber() == 5) and returns null for
54:    // anything else - so "/".toNumber() was null, fell back to 0, and this
57:    // backend rejected it with 422. Char.toNumber() gives the code point.
63:            var v = (chars[i] as Char).toNumber();
```
Only occurrence is `Char.toNumber()` (line 63) plus comments referencing the bug. No
`String.toNumber()` remains. Build verification deferred to Task 9.

---

## Task 2 — Make the save path provable without the watch

STATUS: IN PROGRESS (2a/2b done)

**2a.** `backend/python/app/watch_api.py`: `watch_workout()` now takes `dry_run: int = 0`; after the
`if not w.sets` check, renders `to_liftohistory` and returns `{"recorded": False, "dry_run": True,
"sets": len(w.sets), "liftohistory": text}` without calling `mcp_call`. (There was no duplicated
`text = to_liftohistory(...)` line further down in this codebase's current version of the file — only
one call site existed, so nothing extra to remove.)

**2b.** Added 3 tests to `backend/python/tests/test_watch_api.py`:
- `test_dry_run_renders_without_writing` — posts a compact payload with `?dry_run=1`, monkeypatches
  `plan_mod.mcp_call` to raise if called, asserts 200/`recorded=False`/`dry_run=True`/`sets=2`, and that
  the rendered `liftohistory` contains the program name and grouped sets.
- `test_nul_separated_payload_is_rejected_with_a_clear_error` — builds a realistic Day-3 payload then
  replaces every `|`, `;`, `/` with a NUL byte (reproducing the `%00` encoder bug from commit
  `d084048`) and asserts 422 with "malformed" in the detail. This is the regression marker; kept as
  specified.
- `test_parse_compact_roundtrip_all_days` — loads `dist/plan.json` (source for `PlanData.mc`), for every
  day builds the exact compact-payload shape `pendingText()` uses, URL-escapes/unescapes it (round-trip
  through the wire encoding), and asserts `parse_compact()` recovers the same
  (exercise, weight, reps, amrap) sequence for every logged set. `dist/plan.json` currently only
  contains "Week 1" and "Week 4 - Deload" sections (13 days total incl. one day with 0 exercises
  skipped) — that is the file as it exists on disk; not regenerated per the plan's instruction that
  regeneration is only needed if the tunnel URL changed (it did not).

Command:
```
cd backend/python && .venv/bin/python -m pytest -q
```
Result:
```
53 passed, 1 warning in 1.47s
```
(baseline 50 + 3 new = 53, nothing removed/skipped). Full raw output captured again in Task 9.

### Incident during verification (factual record)

While first testing the dry-run path, a POST with `?dry_run=1` against `http://127.0.0.1:8008` hit the
**live systemd service**, which had been running since 2026-09-13 (before the Task 2a code existed on
disk). The old handler had no `dry_run` parameter, silently ignored the unrecognized query key, and
processed the request as a real save — creating a real Liftosaur history record
(`id: 1789717270000`, dated 2026-09-18, fabricated test data: Squat 220x5/250x5/285x5, etc. under "Day
1"). I stopped immediately, did not attempt to delete it myself, and reported it to the orchestrator
with the record contents. The orchestrator confirmed it restarted `garmin-liftosaur-backend.service`
(now running the Task 2a code) and deleted record `1789717270000` via the Liftosaur MCP, confirming
`History record not found` afterwards. No further action needed on my part; recorded here for the
audit trail. This is also why 2c below has a mandatory capability guard.

**2c.** New file `embedded/monkeyc/tools/verify_watch_payload.py`:
- Mirrors the fixed `Comms.urlEncode()` (`urlencode_mirror()`), with a comment that the two must be
  changed together.
- Builds the compact payload exactly as `WorkoutController.pendingText()` does, for a given day
  (default: first day / Day 1 of `dist/plan.json`), with every set in that day logged.
- Asserts the escaping mapping (`|`→`%7C`, `;`→`%3B`, `/`→`%2F`, no `%00` anywhere) and prints it.
- Computes the escaped URL length for every one of the 14 days in `dist/plan.json` and fails if any
  exceeds 1800 chars (measured worst case: **"Day 6 - Weekend Beast Mode", Week 1, 25 sets, escaped
  length 1044** — well under the 1800 margin).
- **SDK doc citation check (done, not skipped):** grepped every `.html` file under
  `~/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0-2026-06-09-92a1605b2/doc/` — including
  `Toybox/Communications.html` (the `makeWebRequest` reference itself),
  `docs/Core_Topics/Downloading_Content.html`, `docs/Core_Topics/Authenticated_Web_Services.html`, and
  `docs/Core_Topics/HTTPS.html` — for `2048`, `limit`, `maximum`, `URL length`, `truncat*`. **No
  documented request-URL length limit exists anywhere in this SDK's docs** (confirmed again:
  `grep -rl "2048" .../doc/` returns zero files). The plan's "documented 2048-character limit" does not
  have a locatable source; 1800 is used as a conservative engineering guard only, and the tool's source
  comment says so explicitly rather than inventing a citation.
- **Capability guard (mandatory, added per the incident above):** after every non-`--live` POST, the
  tool requires `"dry_run": true` and `"recorded": false` in the parsed response. If either is missing
  or wrong, it prints `REFUSING: backend does not support dry_run ...` to stderr and exits 1 without
  retrying — so a stale backend process can never again be mistaken for a successful dry run.
- `--help` documents that `garmin-liftosaur-backend.service` must be restarted after changing
  `watch_api.py`.

Command (localhost, backend confirmed restarted by orchestrator 2026-09-18 03:42:34 EDT):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
```
Result: escaping table all `OK` (14/14 days), no `%00` in the sample mapping, POST to Day 1 (20 sets)
returned `{"recorded": false, "dry_run": true, "sets": 20, "liftohistory": "...program: \"5/3/1 BBB -
Squat/Bench/Deadlift/OHP\"... week: 1 / dayInWeek: 1 / duration: 3600s ..."}`, capability guard passed
(dry_run confirmed True), final line `OK: round-tripped cleanly, no %00, all sets present in
liftohistory.`

Command (tunnel, default `--backend`, resolved from `LIFT_BACKEND` in `Comms.mc`):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py
```
Result: identical shape — `backend: https://transcripts-forward-acdbentity-ascii.trycloudflare.com`,
all 14 days `OK`, POST to Day 1 returned `{"recorded": false, "dry_run": true, "sets": 20, ...}`,
capability guard passed, `OK: round-tripped cleanly...`.

**2d. Mutation proof.**
```
mkdir -p /tmp/verify_mutation
cp embedded/monkeyc/tools/verify_watch_payload.py /tmp/verify_mutation/verify_watch_payload_mutated.py
```
Mutated the copy only (never touched the repo file): in `urlencode_mirror()`, added an `elif ch == "/":
out.append("%00")` branch before the normal escape branch, reproducing the exact original bug for `/`.
```
cd /tmp/verify_mutation && python3 verify_watch_payload_mutated.py \
  --backend http://127.0.0.1:8008 \
  --comms /home/hermes/repos/garmin-liftosaur/embedded/monkeyc/source/Comms.mc \
  --plan /home/hermes/repos/garmin-liftosaur/dist/plan.json
```
Result: every one of the 14 days reported
`FAIL: found %00 (NUL) in escaped output - the exact bug this tool exists to catch; '/' present in raw
text but %2F missing from escaped output`; sample mapping printed `'/' -> %00`; the FAILURES list
enumerated all 14 days; **exit code 1**; the tool stopped before ever reaching the network POST (proves
the check fails loudly and doesn't silently continue to a live write). Deleted `/tmp/verify_mutation`
afterward. The repo's `tools/verify_watch_payload.py` was never edited during this proof.

---

## Task 3 — Stop the stale-pending corruption

STATUS: DONE

- `Workout.mc`: added `clearPending()` next to `pendingSetCount()` — nulls `_pendingBody`, zeroes
  `_pendingSets`.
- `Comms.mc` `onPostResponse()` success branch: calls `_controller.clearPending();` before
  `Application.Storage.deleteValue(PENDING_KEY);`.
- `Comms.mc`: `PENDING_KEY` bumped from `"lift_pending_workout"` to `"lift_pending_workout_v2"` with a
  comment explaining the v1 key is deliberately abandoned (422-era payloads with the 7.5h garbage
  duration).
- `Workout.mc` `startWorkout()`: calls `clearPending();` right after setting `_started = true`, so a
  fresh session can never inherit a stashed body.

Verification deferred to Task 9 (full build + test gate); no isolated command for this task beyond
reading the diff.

---

## Task 4 — Honest workout duration

STATUS: DONE

- Added `import Toybox.Time;` to `Workout.mc`.
- Replaced field `_sessionMs` with `_startedAt` (0 = unknown). Grepped first (`grep -n "_sessionMs"
  source/Workout.mc`) and confirmed its only 4 uses were: declaration, `initialize()` (=0),
  `startWorkout()` (=`System.getTimer()`), and `elapsedMs()` (the one reader) — so it was fully removed
  rather than left dead, per the plan's "keep `_sessionMs` only if something still reads it".
- `startWorkout()`: `_startedAt = Time.now().value();` in place of the old `System.getTimer()` line.
- `save()` persists `Application.Storage.setValue("lift_started_at", _startedAt);`; `clearSaved()`
  deletes the same key; `restore()` reads it back, defaulting to 0 if absent.
- `elapsedMs()` rewritten exactly as specified: wall-clock delta from `_startedAt`, clamped to
  `[0, 21600]` seconds (0 on a bad/negative/too-large delta), returned in ms.
- Confirmed `System.getTimer()` has zero remaining callers in `Workout.mc`; `System` import is still
  needed (`System.println` remains in `save()`'s log line).

Verification deferred to Task 9.

---

## Task 5 — Kill the "done" exercise sentinel

STATUS: DONE

- `Workout.mc` `currentExerciseName()`: returns `""` (not `"done"`) once `_exIndex` is past the last
  exercise.
- `Workout.mc` `requestExerciseInfo()`: returns early (sets `_info = null`, calls
  `WatchUi.requestUpdate()`) when `isFinished()`, so it never calls `_comms.fetchExerciseInfo("")`.
- `Workout.mc`: added `dayTitle()`, `progressText()`, `elapsedText()` accessors for the finished-state
  summary.
- `WorkoutUi.mc`: `ExerciseInfoView`, `ExerciseHistoryView`, `ExerciseStatsView` — `initialize()` now
  only calls `_c.requestExerciseInfo()` when `!_c.isFinished()`; `onUpdate()` has the shared "WORKOUT
  COMPLETE" guard block (day title, sets, elapsed time, activity/sync notes, "back = return") at the
  top, returning before any exercise-name code runs.
- `WorkoutUi.mc` `SetView`'s "done" branch: kept, still shows no exercise name; added `_c.dayTitle()`
  above the set count and `_c.elapsedText()` below it (repositioned the activity/sync note lines down
  to avoid overlap: `c0-56` DONE, `c0-30` day title, `c0-8` count, `c0+14` elapsed, `c0+36`
  activityNote, `c0+56` syncNote, `c0+92` hold=options).
- `WorkoutUi.mc` rest screen: guarded the `"next  " + currentExerciseName()` line and the weight/reps
  line under it behind `!nextName.equals("")`, so resting after the very last set no longer renders
  `next  ` with a phantom `0 lb x 0`.

Grep check — no source path constructs the literal "done" as an exercise name any more:
```
grep -n '"done"' embedded/monkeyc/source/Workout.mc embedded/monkeyc/source/WorkoutUi.mc
```
Result: only the `mark = isLogged(...) ? "done" : "todo"` line in `Workout.mc` (a per-set logged-marker
string, unrelated to exercise names — not part of this bug) remains. No other occurrence.

Verification that `/watch/exercise?name=done` is never fetched again is a device/journal check
(Acceptance criterion 4) — deferred to sideload time per the plan; cannot be proven from source alone
beyond the grep above and the code-path guard in `requestExerciseInfo()`.

---

## Task 6 — Make the app exitable

STATUS: DONE, with two deliberate deviations from the plan's literal code (documented, per the
resume instructions, rather than silently applied)

**Implemented as specified:**
1. `WorkoutUi.mc` `SetDelegate.onBack()`: now checks `_c.isFinished()` first and does an explicit
   `WatchUi.popView(WatchUi.SLIDE_RIGHT)` instead of unconditionally pushing `AdjustView` — this is the
   literal "I cannot exit" trap fix.
2. `WorkoutUi.mc` `SetMenuDelegate`: added `"Exit app (session kept)"` as the last item in the
   hold-SELECT options menu (`SetDelegate.onMenu()`), and an `"exit"` branch in `onSelect()` that calls
   `_c.save(); System.exit();`.
3. `WorkoutUi.mc` `ListPickerDelegate`: added `onMenu()` (hold SELECT) that pushes a `Menu2` with
   `"Exit app"`, handled by a new `PickerMenuDelegate extends WatchUi.Menu2InputDelegate` whose
   `onSelect()` calls `System.exit()`. `ListPickerDelegate.onBack`/`onSelect` (choose) untouched.
5. `System.exit` confirmed present in `~/.Garmin/ConnectIQ/Devices/venu2s/venu2s.api.debug.xml`:
   `<entry id="8388717" method="true" symbol="exit"/>` (line 4050) and the full
   `<functionEntry accessMode="public" name="exit" parent="System">` doc entry (line 5465, "End
   execution of the current app... @since 1.0.0"). See Task 9 build gate for the `check-device-api.py`
   clean-run confirmation; did not have to fall back to double-`popView`.

**Deviation 1 (from item 2's literal code) — did NOT reset `_exIndex`/`_setIndex` to 0 in
`resolveSave()`.**

The plan's snippet for `resolveSave()` includes `_exIndex = 0; _setIndex = 0;`. I traced the actual
consequence of that and it directly breaks two things the plan itself requires:
- `isFinished()` is defined as `_exIndex >= currentExercises().size()`. Zeroing `_exIndex` after
  Save/Discard makes `isFinished()` **false** the instant the finish `Menu2` pops back to `SetView`.
- `SetView.onUpdate()`'s "done" branch (Task 5, which I already implemented per-spec using
  `_c.isFinished()`) would then no longer match, and the view falls through to the ordinary
  "working screen" branch — showing exercise 1's weight/reps as if a fresh set were in progress, on a
  workout that was just saved.
- `SetDelegate.onBack()` (item 1 above, also per-spec, checks `_c.isFinished()`) would then also no
  longer match, so BACK would go back to pushing `AdjustView` — **exactly the bug Task 6 exists to
  fix**, reintroduced one level down.
- This directly contradicts the plan's own Acceptance criterion 5: "After Save/Discard the DONE screen
  still reports the result ... and BACK from it returns to the day picker."

I also checked whether the cursor reset was needed for a *future* workout attempt (the stated
motivation: "so a popped-back view can never fall into the DONE state again"): `selectDay()`
(`Workout.mc`) already unconditionally resets `_exIndex`, `_setIndex`, and rebuilds `_weights`/`_reps`/
`_logged` from scratch every time a day is navigated to on the picker — so any future `startWorkout()`
reached via normal picker navigation already starts clean regardless of what `resolveSave()` leaves
behind. The only leftover gap (re-pressing SELECT on the *same* day without navigating away first,
which skips `selectDay()`) was already just as broken before this change and is not covered by the
plan's acceptance criteria.

I kept every other reset from the plan's snippet (`_awaitingReps`, `_repsEditing`, `_started`,
`_startedAt`, `_sessionStopped`, `clearSaved()`, `clearPending()`), added a comment at the omission
point explaining it, and left a pointer to this PROGRESS.md section in the source comment.

**Known minor side effect (not fixed, out of scope):** because `_started` still becomes `false` in
`resolveSave()` (per spec), `elapsedMs()`/`elapsedText()` (Task 5's addition to the DONE screen) drops
to "0 min" the instant Save/Discard is chosen, having shown the real elapsed time right before. This
is cosmetic, not a data-correctness or exit-blocking issue, and freezing the value wasn't asked for —
flagging it rather than silently "fixing" something outside the plan's scope.

**Deviation 2 (addition beyond the plan's literal code) — `resolveSave()` now no-ops if `!_started`.**

Because the cursor is *not* reset (deviation 1), `isFinished()` stays true after Save/Discard, so the
pre-existing "pressing the top button calls `finishWorkout()` again" behavior (named in the diagnosis
as a symptom, not explicitly required to be fixed) is unchanged - the Save/Discard `Menu2` can still be
re-opened from the DONE screen. Without a guard, choosing "Save & finish" a second time would call
`_comms.postWorkout()` again with the same `_weights`/`_reps`/`_logged` (unchanged since the first
save) and write a **duplicate real record into the user's Liftosaur history** - the same class of
incident that happened once already during this task's verification (see Task 2's incident note). I
added a one-line idempotency guard at the top of `resolveSave()`: `if (!_started) { return; }` (the
first `resolveSave()` call always runs with `_started == true`; it sets `_started = false` at the end,
so a second call is a safe, complete no-op - no re-post, no re-touching the Garmin session, notes
unchanged). This is a data-safety addition, not a UI/input-map change, so it does not conflict with
"nothing else about the input map may change."

Verification (build + `check-device-api.py`) deferred to Task 9.

---

## Task 7 — De-clutter the exercise history (scrolling list)

STATUS: DONE

**1. Backend** — `backend/python/app/plan.py` `exercise_history()`: `"recent": sessions[:5]` ->
`sessions[:12]` (with a comment); `get_history(limit=20)` unchanged. Added
`test_exercise_history_recent_is_capped_and_small` to `tests/test_watch_api.py`: builds a 15-session
fixture for "Squat", asserts `exercise_history()` and the `/watch/exercise` endpoint both cap at 12
(not 15), and asserts the JSON payload size.

Command:
```
cd backend/python && .venv/bin/python -c "... measure exercise_history() JSON size for 12 sessions ..."
```
Result: `sessions: 12`, `bytes: 2407` — well under the 4000-byte budget. Full suite:
```
cd backend/python && .venv/bin/python -m pytest -q
```
Result: `54 passed` (53 + 1 new).

**2. Controller** — `Workout.mc`:
- Factored the "NxR W" run-collapsing (previously duplicated inline in `infoRecentLines()`, and again
  with slightly different formatting in `infoSetsText()`/`infoSetLines()`) into one private helper
  `_groupRuns(sets)`, used by the two new history-list functions below.
- Added `historyCount()`, `historyLabel(i)` ("Sep 10  -  top 305"), `historySublabel(i)` (<=22 chars,
  breaks before exceeding the cap), `historyDetailLines(i)` (<=20 chars/line, same wrapping rule as
  `infoSetLines()`), `selectHistory(i)`/`selectedHistory()`, plus `historyDateText/TopText/E1rmText/
  VolumeText(i)` (not in the plan's literal stub list, but needed for the detail view's "lines plus
  top/e1rm/volume" per the plan's prose — all read straight from the backend's already-computed
  `top_weight`/`e1rm`/`volume` fields, no recomputation).
- Added `_historyIndex` field (which session the list has open), reset in `initialize()` and whenever
  `setExerciseInfo()` receives fresh data (so a stale selection can never point past the end of a
  shorter new list).
- **Deviation (cleanup, not behavior):** deleted `infoRecentLines()` — after wiring the new list, it
  had zero remaining callers (verified: `grep -rn infoRecentLines source/*.mc` returns nothing but the
  helper's own comment). Left as dead code, it would have been exactly the kind of unused function the
  house rules say to delete outright rather than leave around.

**3. Views** — replaced `ExerciseHistoryView`'s body:
- It is now a small **loading gate**: shows the same "WORKOUT COMPLETE" guard (Task 5) when finished,
  "loading..." while the async fetch is in flight, "no history yet" if the count is 0, and otherwise
  calls `WatchUi.switchToView(buildHistoryList(_c), new HistoryListDelegate(_c), SLIDE_LEFT)` **once**
  (guarded by a `_switched` flag so a second `onUpdate()` before the transition completes can't
  re-trigger it).
  - **Deviation (mechanism, not requirements):** used `WatchUi.switchToView()` (confirmed present in
    the venu2s device API, "Pop the current View from the View stack and push a new one") instead of
    `WatchUi.pushView()` for this specific transition. Reasoning: history data loads asynchronously, so
    the Menu2 list can't be built at `initialize()` time the way `buildSetList()` can (that data is
    already local). Using `pushView` here would leave the loading-gate View sitting on the stack
    *underneath* the Menu2, so `HistoryListDelegate.onBack()` would only pop back to a blank gate
      screen, not to the set screen - contradicting the plan's own requirement ("BACK from the list ->
      back to the set screen"). `switchToView` replaces the gate in place, so the stack is
      `SetView -> Menu2` and `onBack()` pops directly to `SetView`, matching spec.
- `buildHistoryList(c)` + `HistoryListDelegate` (`Menu2InputDelegate`): one `MenuItem` per session
  (`historyLabel`/`historySublabel`), tap -> `selectHistory(i)` then `pushView(HistoryDetailView, ...)`;
  `onBack()` pops to the set screen.
- `HistoryDetailView` (`WatchUi.View`): that session's grouped set lines (up to 4, `FONT_SMALL`) plus
  top/e1rm/volume, pushed with the existing read-only `InfoDelegate` (BACK/SELECT both pop back to the
  list) — exactly as the plan specifies ("Keep the read-only InfoDelegate behaviour for the detail
  page").
- `openHistory()` in `SetDelegate` is unchanged (`pushView(new ExerciseHistoryView(_c), new
  InfoDelegate(_c), SLIDE_LEFT)`); the gate view still uses `InfoDelegate` for its own
  loading/empty/finished states.

**4.** `ExerciseInfoView` (3 lines, 20 chars) and `ExerciseStatsView` left as-is beyond Task 5's
`isFinished()` guard — not touched further, per the plan.

Device-only acceptance (">=8 sessions, scrolls, nothing overflows, one tap to detail") cannot be proven
from source; deferred to sideload per the plan. Build/API-symbol verification deferred to Task 9.

---

## Task 8 — Correct `week`/`dayInWeek` in the uploaded record

STATUS: DONE

- `Workout.mc`: added `_trailingNumber(s)` (private helper — scans right-to-left for the last run of
  digits, returns it as a Number, 0 if none), `weekNumber()` (from `currentDay()[:section]`, e.g.
  "Week 3" -> 3, falls back to 1) and `dayInWeek()` (from `currentDay()[:name]`, e.g. "Day 4" -> 4,
  falls back to 1).
- `buildWorkoutBody()`: `:week => 1` / `:day_in_week => _dayIndex + 1` replaced with
  `:week => weekNumber()` / `:day_in_week => dayInWeek()`.
- `loadPendingText()`: left `:week => 1, :day_in_week => 1` exactly as-is, with a comment explaining
  why (a stashed workout carries no day context to derive week/day from — `pendingText()`'s compact
  format doesn't include section, and by the time a stash is replayed `_dayIndex` may no longer point
  at the day that produced it).
- Extended `tools/verify_watch_payload.py` (Task 2c) with `trailing_number()`/`week_and_day()` — Python
  mirrors of the same right-to-left digit-scan, with a comment that the two must stay in lockstep — and
  a printed `day -> week/dayInWeek` table for every day in `dist/plan.json`.

Command (localhost):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
```
Table (identical against both backends, see Task 9 for the tunnel run's full raw output):
```
day -> week/dayInWeek (derived from section/name, not list index):
  Day 1                                    Week 1             -> week 1, dayInWeek 1
  Day 2                                    Week 1             -> week 1, dayInWeek 2
  Day 3                                    Week 1             -> week 1, dayInWeek 3
  Day 4                                    Week 1             -> week 1, dayInWeek 4
  Day 5 - Light Pump (Wed)                 Week 1             -> week 1, dayInWeek 5
  Day 6 - Weekend Beast Mode               Week 1             -> week 1, dayInWeek 6
  Day 7 - Travel Bodyweight                Week 1             -> week 1, dayInWeek 7
  Day 1                                    Week 4 - Deload    -> week 4, dayInWeek 1
  Day 2                                    Week 4 - Deload    -> week 4, dayInWeek 2
  Day 3                                    Week 4 - Deload    -> week 4, dayInWeek 3
  Day 4                                    Week 4 - Deload    -> week 4, dayInWeek 4
  Day 5 - Light Pump (Deload)              Week 4 - Deload    -> week 4, dayInWeek 5
  Day 6 - Weekend Beast (Deload)           Week 4 - Deload    -> week 4, dayInWeek 6
  Day 7 - Travel Bodyweight (Deload)       Week 4 - Deload    -> week 4, dayInWeek 7
```
All Week-1 days read `week 1`; all Week 4 Deload days read `week 4`, `dayInWeek` 1-7 in both blocks —
matches the acceptance criterion exactly. `dist/plan.json` only has these two sections on disk (not
regenerated, per the plan's instruction — the tunnel URL hasn't changed), so Week 2/3 aren't exercised
by this specific tool run, but `PlanData.mc` (the actual embedded plan) carries all four weeks with the
identical `"Week N"`/`"Day N"` naming convention the parser reads, so the same digit-scan applies
uniformly.

---

## Cosmetic fix (self-flagged in Task 6) — elapsed time freezing at "0 min" after Save/Discard

STATUS: DONE

Task 6's PROGRESS note flagged that because `resolveSave()` sets `_started = false` (per the plan's
spec), `elapsedMs()` (Task 4, wall-clock, short-circuits to 0 when `!_started`) would make the DONE
screen's `elapsedText()` drop from the real duration to "0 min" the instant Save/Discard is chosen.

Fix: added `_finalElapsedMs` field (-1 = not resolved yet), reset to -1 in `initialize()` and
`startWorkout()` (fresh session). In `resolveSave()`, added `_finalElapsedMs = elapsedMs();` as the
**first** statement after the `!_started` guard's early return and before `_started`/`_startedAt` are
cleared, with a comment explaining why the ordering matters. `elapsedText()` now reads
`(_finalElapsedMs >= 0) ? _finalElapsedMs : elapsedMs()` — live while the workout is in progress or
sitting on the pre-resolve DONE screen, frozen at the true value once Save/Discard is chosen.

---

## Task 9 — Build, test, prove

STATUS: DONE. All gates run myself, raw output below, nothing removed or skipped.

### 1. Backend pytest

Command:
```
cd backend/python && .venv/bin/python -m pytest -q
```
Raw output:
```
......................................................                   [100%]
=============================== warnings summary ===============================
.venv/lib/python3.11/site-packages/fastapi/testclient.py:1
  /home/hermes/repos/garmin-liftosaur/backend/python/.venv/lib/python3.11/site-packages/fastapi/testclient.py:1: StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
    from starlette.testclient import TestClient as TestClient  # noqa

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
54 passed, 1 warning in 2.04s
```
Baseline was 50 passed; this session added 4 new tests (`test_dry_run_renders_without_writing`,
`test_nul_separated_payload_is_rejected_with_a_clear_error`, `test_parse_compact_roundtrip_all_days`,
`test_exercise_history_recent_is_capped_and_small`) = 54. `git diff` on `tests/test_watch_api.py` has
**zero removed lines** (confirmed below) — nothing weakened or deleted.

### 2. `venu2s` build

Command:
```
cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s
```
Raw output (warnings are all pre-existing, in files this plan explicitly parks — `LiftBinary.mc`,
`LiftBleTransport.mc`, `LiftFrame.mc`, `SampleBuffer.mc`, `Transport.mc` — or are pre-existing in
untouched code in `Workout.mc`/`WorkoutUi.mc`; see the "warnings audit" note below):
```
SDK: /home/hermes/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0-2026-06-09-92a1605b2
key: developer_key.der (4096-bit)
Building for venu2s...
[... 60+ pre-existing "Cannot determine if container access/assignment is using container type"
     warnings in LiftBinary.mc, LiftBleTransport.mc, LiftFrame.mc, SampleBuffer.mc, Transport.mc,
     Workout.mc, WorkoutUi.mc, and 2 pre-existing "Statement is not reachable" warnings
     (LiftBleTransport.mc:538, SampleBuffer.mc:51) - full list in the terminal output above ...]
WARNING: venu2s: /home/hermes/repos/garmin-liftosaur/embedded/monkeyc/source/Workout.mc:297,16: Statement is not reachable.
WARNING: venu2s: /home/hermes/repos/garmin-liftosaur/embedded/monkeyc/source/WorkoutUi.mc:866: Member variable '_c' is not used.
BUILD SUCCESSFUL
Built bin/Liftosaur.prg (219276 bytes) target=006-B3704-00

check-device-api: all 71 module calls exist on 'venu2s'

Sideload:  copy bin/Liftosaur.prg to GARMIN/APPS over MTP, then PHYSICALLY
           UNPLUG the watch (that is when it installs). See
           docs/03-garmin-toolchain-and-sideload.md
```
**No `Symbol Not Found` warnings anywhere.** `check-device-api` clean (71/71).

**Warnings audit (traced each one, not just skimmed):**
- The bulk ("Cannot determine if container access/assignment...") are pre-existing across
  `LiftBinary.mc`, `LiftBleTransport.mc`, `LiftFrame.mc`, `SampleBuffer.mc`, `Transport.mc` — all
  explicitly parked/do-not-touch files; untouched this session.
- `Workout.mc:297,16: Statement is not reachable` — inside `startWorkout()`'s
  `if (_session == null) { _activityNote = "activity not started"; }` branch. Checked via
  `git diff -- embedded/monkeyc/source/Workout.mc`: this exact branch is untouched by this session's
  diff (only a `_finalElapsedMs = -1;` line was added a few lines above it); pre-existing.
- `WorkoutUi.mc:866: Member variable '_c' is not used` — `InfoDelegate._c`, set in `initialize()` but
  never read by `onBack()`/`onSelect()` (both just `popView`). Confirmed via `git show HEAD:... | grep
  -n "class InfoDelegate" -A 15`: identical in the pre-session version. Pre-existing, not introduced;
  `InfoDelegate`'s own body was never touched this session (only new call sites that construct it).

### 3. `verify_watch_payload.py` against both backends

Ran after the build, with the backend confirmed running the current `dry_run`-aware code (restarted by
the orchestrator earlier at 2026-09-18 03:42:34 EDT; nothing in this session's later backend edits
—`plan.py`'s `exercise_history` cap— touches the `/watch/workout` path this tool exercises, so no
further restart was needed for this specific gate).

Command (localhost):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
```
Result: all 14 days `OK` on escaping/length, the week/dayInWeek table (Task 8) correct for every day,
sample escaping table has no `%00`, POST to Day 1 (20 sets) returned
`{"recorded": false, "dry_run": true, "sets": 20, "liftohistory": "...program: \"5/3/1 BBB -
Squat/Bench/Deadlift/OHP\"... week: 1 / dayInWeek: 1 / duration: 3600s ..."}`, capability guard
confirmed `dry_run: true`, final line `OK: round-tripped cleanly, no %00, all sets present in
liftohistory.`

Command (tunnel, default `--backend` resolved from `LIFT_BACKEND` in `Comms.mc`):
```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py
```
Result: `backend: https://transcripts-forward-acdbentity-ascii.trycloudflare.com`, identical shape —
all 14 days `OK`, week/dayInWeek table correct, POST to Day 1 returned `{"recorded": false, "dry_run":
true, "sets": 20, ...}`, capability guard passed, `OK: round-tripped cleanly...`.

### 4. Mutation proof (re-run, since the tool grew substantially since Task 2d)

```
mkdir -p /tmp/verify_mutation2
cp embedded/monkeyc/tools/verify_watch_payload.py /tmp/verify_mutation2/verify_watch_payload_mutated.py
```
Mutated the copy only: added `elif ch == "/": out.append("%00")` to `urlencode_mirror()`.
```
cd /tmp/verify_mutation2 && python3 verify_watch_payload_mutated.py \
  --backend http://127.0.0.1:8008 \
  --comms /home/hermes/repos/garmin-liftosaur/embedded/monkeyc/source/Comms.mc \
  --plan /home/hermes/repos/garmin-liftosaur/dist/plan.json
```
Result: all 14 days `FAIL: found %00 (NUL) in escaped output ...; '/' present in raw text but %2F
missing from escaped output`; sample mapping printed `'/' -> %00`; **exit code 1**; stopped before any
network POST. Deleted `/tmp/verify_mutation2` afterward. Repo file never touched.

### 5. `git diff --stat` and diff re-read

```
git diff --stat
```
```
 backend/python/app/plan.py             |   6 +-
 backend/python/app/watch_api.py        |   6 +-
 backend/python/tests/test_watch_api.py | 105 +++++++++++++
 embedded/monkeyc/source/Comms.mc       |  49 +++---
 embedded/monkeyc/source/Workout.mc     | 275 ++++++++++++++++++++++++++++-----
 embedded/monkeyc/source/WorkoutUi.mc   | 235 ++++++++++++++++++++++++----
 6 files changed, 587 insertions(+), 89 deletions(-)
```
Read every removed line in each file (`git diff | grep '^-' | grep -v '^---'`) against the task list
above:
- `Comms.mc`: only the old `urlEncode` body (Task 1) and the old `PENDING_KEY` value (Task 3) removed.
- `Workout.mc`: `_sessionMs` field/uses (Task 4, replaced by `_startedAt`), the `"done"` sentinel
  (Task 5), the old one-line `setExerciseInfo` (Task 7, now also resets `_historyIndex`), the full old
  `infoRecentLines()` body (Task 7, dead after the rewrite), `:week => 1, :day_in_week => _dayIndex + 1`
  (Task 8), the old timer-based `elapsedMs()` body (Task 4).
- `WorkoutUi.mc`: the unguarded rest-screen "next" line (Task 5), the old "done" branch body (Task 5/6),
  the unconditional `requestExerciseInfo()` calls in three view `initialize()`s (Task 5, now guarded),
  and the entire old `ExerciseHistoryView` body (Task 7, replaced).
- `plan.py`/`watch_api.py`: only `sessions[:5]` (Task 7) and the `watch_workout` signature line (Task
  2a, replaced to add `dry_run`).
- `tests/test_watch_api.py`: **zero removed lines** — pure additions.

Nothing unaccounted-for or accidental found.

---

## Task 10 — Ship the artifact and write it down

STATUS: DONE

**1. Artifact.**
```
cp embedded/monkeyc/bin/Liftosaur.prg dist/Liftosaur.prg
cd dist && sha256sum Liftosaur.prg > Liftosaur.prg.sha256
```
Result: `dist/Liftosaur.prg` is 219276 bytes (matches `bin/Liftosaur.prg` exactly — `sha256sum` on both
gives the identical digest `6b6de9b7286992889df293fdafb70c670bd2e81f9b77c34cfe2b56a8e80be477`).
`dist/Liftosaur.prg.sha256` now contains `6b6de9b7...be477  Liftosaur.prg`.

**Note on the sidecar format:** the pre-existing `dist/Liftosaur.prg.sha256` (before this task) was 17
bytes / an abbreviated 16-hex-char string, not a standard `sha256sum` digest — it did not match the
format of the other sidecar in the same directory, `Liftosaur.preBLE-diagnostic.prg.sha256` (a normal
`<64-hex>  <filename>` line, the literal output of `sha256sum <file> > <file>.sha256`). I generated the
new sidecar with plain `sha256sum`, matching the `preBLE-diagnostic` sidecar's format rather than
replicating the old file's apparently-truncated one.

**2. `docs/06-sync.md`** — added a "What went wrong: the `%00` encoder regression" section: the
`String.toNumber()` vs `Char.toNumber()` root cause with the code snippet, the exact journal line as
evidence, the fact that the previous build (pre-`d084048`) posted fine, the secondary stale-stash bug
and the `_v2` key bump. Also updated the "Verifying sync without the watch" section to lead with
`tools/verify_watch_payload.py` (dry-run, safe) ahead of `plan_from_liftosaur.py --post` (real write),
and refreshed the stale `35 passed` figure to `54 passed`.

**3. `docs/05-watch-workout-app.md`** — added:
- "End-of-workout summary and exit paths" section: the `"done"` sentinel fix, the BACK-to-day-picker
  fix, both new "Exit app" menu items, and why `resolveSave()` deliberately doesn't reset the cursor.
- "Exercise history" section: the scrolling `Menu2` list replacing the old fixed 5-line block, the
  12-session server cap.
- "Duration, week, and day fields (corrected 2026-09-18)" section: wall-clock duration with the 7.5h
  real-payload example, and section/name-derived week/dayInWeek with the "week 1, dayInWeek 15" real
  example.
- Updated the controls tables (set screen + day picker) to reflect the new exit menu items.
- Updated "Known gaps": removed the stale "No sync-back to Liftosaur (needs https)" line (resolved) and
  replaced it with the honest remaining gap — hardware confirmation of the fixed encoder.

**4. Final `check-device-api.py` run:**
```
cd embedded/monkeyc && python3 tools/check-device-api.py --device venu2s --source-dir source
```
Result: `check-device-api: all 71 module calls exist on 'venu2s'`.

---

## Final status

All 10 tasks DONE. No task left TODO or IN PROGRESS. `dist/Liftosaur.prg` + `.sha256` reflect this
session's build. Every gate was run and its raw output pasted above (backend pytest, the venu2s build,
`verify_watch_payload.py` against both the tunnel and localhost, and two independent mutation proofs of
the escaping check). `git diff` was read in full; nothing was removed that shouldn't have been, and no
existing test assertion was weakened, skipped, or deleted. One real incident occurred during
verification (a stale, pre-restart backend process turned a dry-run POST into a real Liftosaur write);
it is documented under Task 2, was not caused by `--live`, and the resulting record was deleted by the
orchestrator — not by me. Two deliberate deviations from the plan's literal code (Task 6's `resolveSave`
cursor reset, replaced with a narrower fix) are documented with full reasoning under Task 6. The parked
BLE files and `docs/04` were never touched (confirmed via `git diff --stat`, which lists only
`Comms.mc`, `Workout.mc`, `WorkoutUi.mc`, and the three backend files). No `--live` run, no `git push`,
no `git checkout -- <file>` on uncommitted work.

**What the user still has to do:** sideload `dist/Liftosaur.prg` — watch → Settings → System → USB Mode
→ **MTP**, plug in a data-capable cable, copy the `.prg` into `GARMIN/APPS`, then **physically unplug
the watch** (that is when it installs). Then: run a workout → **Save & finish** → the summary must read
`synced to Liftosaur`, and the record must appear in Liftosaur with the right week/day and a sane
duration. The device test is the only remaining proof that the fixed Monkey C encoder runs correctly on
hardware; everything else in this plan has been proven off-device.
