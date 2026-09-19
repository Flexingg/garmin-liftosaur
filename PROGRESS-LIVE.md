# Progress — Live sync: push each completed set to Liftosaur as the workout happens

Plan: `.hermes/plans/2026-09-18_190500-live-sync-per-set.md`

Scope for this session (per orchestrator instructions): Tasks 1-4 and 6. **Task 5's real
create/update/delete cycle against the live account is explicitly OUT OF SCOPE** — that is
Hermes' step. Every verification in this session uses `dry_run=1` or a local backend, never a
real Liftosaur write. The exact commands for the real cycle are left below (see "Device protocol"
and "Task 5 — orchestrator's step") for Hermes to run.

User's decisions (do not re-litigate):
1. The record is created on the first completed set, then updated after every set.
2. Discard deletes the live record — nothing left behind in Liftosaur.
3. No new watch UI — sync is silent; failures are invisible.

| Task | Status | Notes |
|---|---|---|
| 1. Backend: live endpoint (create then update) | DONE | see below |
| 2. Backend: discard endpoint | DONE | see below |
| 3. Watch: push each set, remember the record id | DONE | see below; deviation noted |
| 4. Backend tests | DONE | 11 new, see below |
| 5. Off-device proof + real cycle | ORCHESTRATOR'S STEP | commands left below, not run by this session |
| 6. Docs, artifact, gates | DONE | see below |

---

## Baseline

```
cd backend/python && .venv/bin/python -m pytest -q
```
Result: `54 passed, 1 warning in 2.51s` (2026-09-18, before any changes this session).

---

## Task 1 — Backend: live endpoint (create then update)

STATUS: DONE

**File:** `backend/python/app/watch_api.py`

- `parse_compact()`: header now accepts an optional 5th field, `started_at` (unix seconds). A
  4-field header still parses exactly as before (existing stash payloads are unaffected).
  `WorkoutIn` gained `started_at: int | None`.
- `to_liftohistory(w, plan=None, stamp=None)`: `stamp` overrides `w.finished_at`/`now()` when
  given. Docstring documents the fallback chain and that `now()` as a last resort can shift a
  record's date once across a service restart with no `started_at`.
- `POST /watch/workout/live` (`payload`, `record=""`, `dry_run=0`):
  - malformed header / no sets -> 422, same semantics as `/watch/workout`;
  - never-shrink guard: if `_LIVE_SET_COUNTS[record] > len(sets)`, returns
    `{"id": record, "skipped": "stale", "sets": n}` without writing or calling Liftosaur;
  - stamp resolved via `_live_stamp()`: `started_at` from the payload, else the stamp remembered
    in `_LIVE_STAMPS` when the record was created, else `now()`;
  - `dry_run=1` -> `{"recorded": False, "dry_run": True, "id": record or "dry", "sets": n,
    "liftohistory": text}`, never calls `mcp_call`;
  - `record == ""` -> `create_history_record`, validated by `_write_result()` (same
    rejection-vs-success shape as `watch_workout`'s existing check: a rejected write raises
    `_RecordRejected`, turned into a 502, never reported as success);
  - `record` set -> `update_history_record({"id": record, "text": text})`; if the response is a
    rejection (record gone), falls back to `_create_live_record()` and returns `created: True`
    with the new id — the workout is never lost;
  - `_LIVE_STAMPS`/`_LIVE_SET_COUNTS` are in-memory dicts keyed by the record id (always a string,
    since it travels as a URL query param); best-effort bookkeeping only, not a durable store.

## Task 2 — Backend: discard endpoint

STATUS: DONE

- `POST /watch/workout/discard` (`record=""`, `dry_run=0`):
  - `dry_run=1` -> `{"deleted": False, "dry_run": True, "id": record}`, no Liftosaur call;
  - empty `record` -> `{"deleted": False, "reason": "no record"}` (not an error);
  - otherwise `delete_history_record({"id": record})`; a response containing "not found"
    (case-insensitive) is reported as `{"deleted": True, "id": record, "reason": "already gone"}`
    rather than a 502, matching the plan's "nothing left behind is what matters" framing;
  - clears the record's `_LIVE_STAMPS`/`_LIVE_SET_COUNTS` entries whatever the result.

## Task 4 — Backend tests

STATUS: DONE — all 8 points from the plan covered, 11 new tests in
`backend/python/tests/test_watch_api.py`:

1. `test_live_payload_without_a_record_creates_a_record`
2. `test_live_payload_with_a_record_updates_it` (asserts the FULL text, not a delta)
3. `test_update_falls_back_to_create_when_the_record_is_gone`
4. `test_a_stale_shorter_payload_does_not_shrink_the_record`
5. `test_live_timestamp_is_stable_across_updates` + `test_live_payload_without_started_at_still_parses`
6. `test_discard_deletes_the_record`, `test_discard_with_no_record_is_a_no_op`,
   `test_discard_of_a_missing_record_is_not_an_error`
7. `test_live_dry_run_writes_nothing`, `test_discard_dry_run_writes_nothing`
8. Existing suite untouched and still green (see gate output below) — nothing removed or weakened.

**Test-pollution fix needed:** `_LIVE_STAMPS`/`_LIVE_SET_COUNTS` are module-level dicts, so a
record id reused across two test functions (e.g. `"111"`) carried a stale set count from an
earlier test and made `test_live_timestamp_is_stable_across_updates` spuriously report
`skipped: "stale"`. Added an autouse fixture `_reset_live_sync_state` that clears both dicts
before every test in the file. This is test-only; production behaviour is unchanged.

```
cd backend/python && .venv/bin/python -m pytest -q
```
Result: `65 passed, 1 warning in 1.47s` (54 baseline + 11 new, nothing removed or weakened).

---

## Task 3 — Watch: push each set, remember the record id

STATUS: DONE

**Files:** `embedded/monkeyc/source/Comms.mc`, `embedded/monkeyc/source/Workout.mc`

- **3a. Storage.** `lift_live_record` and `lift_pending_record` (String; absent = none). Both
  cleared in `WorkoutController.clearSaved()`.
- **3b. Payload.** `WorkoutController.livePayload()` added, sharing a new private `_compact(body,
  startedAt)` helper with `pendingText()` (was duplicated inline before; factored out so the two
  formats cannot drift). `pendingText()` calls `_compact(body, null)` (4 fields, unchanged
  output); `livePayload()` calls `_compact(buildWorkoutBody(), _startedAt)` (5 fields, always the
  CURRENT cursor, never a reloaded stash).
- **3c. `Comms.postLiveSet()`** — called from `completeSet()` immediately after `markLap()`.
  In-flight/queued flags (`_liveInFlight`/`_liveQueued`) enforce one request at a time; a set
  completed while one is in flight sets the queued flag and, on response, re-reads
  `_controller.livePayload()` fresh (the "current, longer" payload) rather than replaying a stale
  one. On 2xx with a dict body carrying `id`, stores it under `lift_live_record`. On any failure
  (bad status or non-dict body): clears the in-flight flag, logs via `System.println`, touches no
  other state, and does not stash — silent per decision #3.
- **3d. `resolveSave()` integration:**
  - Save: `Comms.postWorkout()` now POSTs to `/api/v1/watch/workout/live` (not `/watch/workout`)
    with `&record=<id or "">`, reusing the SAME endpoint's create-or-update logic instead of
    duplicating it — "no id stored" behaves exactly like today's create, "id stored" updates it.
  - Discard: `Comms.discardLive()` → `POST /api/v1/watch/workout/discard?record=<id>`; the id is
    deleted from `lift_live_record` locally before the request is even sent, so it's gone
    regardless of the network result.
- **3e. Stash must not duplicate.** `stashPending()` now also writes `lift_pending_record`;
  `postWorkout()`'s record selection prefers `lift_live_record`, falling back to
  `lift_pending_record` — so a background retry at app start (which never goes through
  `resolveSave()`/`clearSaved()`) still updates the same record. `onPostResponse()`'s success
  branch now also deletes both keys (belt-and-suspenders for the retry-at-app-start path, which
  bypasses `clearSaved()` entirely).

**Deviation from the plan's literal text, documented per the resume rules.** Plan 3a says "Clear
both [`lift_live_record`/`lift_pending_record`] in `clearSaved()`." Plan 3d says Save's
`postWorkout()` should pass the live record id in, and 3e says a FAILED save's `stashPending()`
should stash that same id for the retry. Literally: `resolveSave()` calls `postWorkout()`
(dispatches the async POST) and THEN, in the same synchronous call, `clearSaved()` — which per 3a
wipes `lift_live_record` from Storage — all before the async response (and a possible
`stashPending()`) can run. By the time a failure callback fires, `lift_live_record` would already
be gone, so `stashPending()` could not read out which record to remember for the retry.
**Fix:** `LiftComms` remembers the id it used for the in-flight dispatch in an instance variable,
`_lastRecordId`, set synchronously inside `postWorkout()` before the network call returns.
`stashPending()` reads `_lastRecordId` (not Storage) when writing `lift_pending_record`. `3a`'s
instruction is still honored literally (`clearSaved()` deletes both keys); the fix is entirely
inside `Comms.mc` and changes no plan-specified behaviour.

```
cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s
```
Result: `BUILD SUCCESSFUL`, `bin/Liftosaur.prg (234748 bytes)`, `check-device-api: all 77 module
calls exist on 'venu2s'`. No new warnings in `Comms.mc`/`Workout.mc` beyond the pre-existing
baseline ones (same files/lines as before this session: `SampleBuffer.mc`, `Transport.mc`, plus
long-standing "Cannot determine if container access is using container type" notes throughout
`Workout.mc`/`WorkoutUi.mc` that predate this change).

---

## Manual dry-run verification of the two new endpoints (local backend, restarted with new code)

`systemctl --user restart garmin-liftosaur-backend.service` (to pick up this session's code),
then:

```
curl -sS -X POST "http://127.0.0.1:8008/api/v1/watch/workout/live?payload=Day%201%7CWeek%201%7C5%2F3%2F1%20BBB%7C120%7C1700000000%3BSquat%7C220%7C5%7C0&record=&dry_run=1"
```
Result: `{"recorded": false, "dry_run": true, "id": "dry", "sets": 1, "liftohistory": "2023-11-14T22:13:20Z / ..."}`
— create-shaped dry output, timestamp taken from the payload's `started_at` field (1700000000).

```
curl -sS -X POST "http://127.0.0.1:8008/api/v1/watch/workout/live?payload=Day%201%7CWeek%201%7C5%2F3%2F1%20BBB%7C120%7C1700000000%3BSquat%7C220%7C5%7C0%3BSquat%7C250%7C5%7C0&record=dry&dry_run=1"
```
Result: `{"recorded": false, "dry_run": true, "id": "dry", "sets": 2, "liftohistory": "...same stamp, both sets present..."}`
— update-shaped dry output, same leading timestamp as the first call.

```
curl -sS -X POST "http://127.0.0.1:8008/api/v1/watch/workout/discard?record=dry&dry_run=1"
curl -sS -X POST "http://127.0.0.1:8008/api/v1/watch/workout/discard?dry_run=1"
```
Results: `{"deleted": false, "dry_run": true, "id": "dry"}` and
`{"deleted": false, "dry_run": true, "id": ""}` — neither touches Liftosaur.

```
curl -sS -o /dev/null -w "%{http_code}\n" -X POST "http://127.0.0.1:8008/api/v1/watch/workout/live?record=&dry_run=1"
```
Result: `422` (no payload).

No real Liftosaur write occurred in any of the above — every call carried `dry_run=1`.

## Task 6 gates

```
cd backend/python && .venv/bin/python -m pytest -q
```
Result: `65 passed, 1 warning in 1.47s` (unchanged since Task 4 — no further backend edits after
this point).

```
cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s
```
Result: `BUILD SUCCESSFUL`, `bin/Liftosaur.prg (234748 bytes)`, `check-device-api: all 77 module
calls exist on 'venu2s'` (same as the Task 3 build — no further watch edits after that point).

```
cd embedded/monkeyc && python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
cd embedded/monkeyc && python3 tools/verify_watch_payload.py   # tunnel (LIFT_BACKEND in Comms.mc)
```
Both: every day in `dist/plan.json` round-trips cleanly (no `%00`, length under the safety
margin), and the `/watch/workout` dry-run POST for Day 1 returns
`{"recorded": false, "dry_run": true, "sets": 20, "liftohistory": "..."}`. `OK: round-tripped
cleanly, no %00, all sets present in liftohistory.` for both localhost and tunnel.

Note: `verify_watch_payload.py` itself was **not** extended with `--live-flow` (plan Task 5, item
1) — the orchestrator's scope for this session is Tasks 1-4 and 6 only; Task 5 in its entirety
(including that extension) is left for Hermes. The two new endpoints were instead verified
directly with the curl calls above, all under `dry_run=1`.

## Task 6 — Docs, artifact, gates

STATUS: DONE

- `docs/05-watch-workout-app.md`: new "Live sync (2026-09-18)" section (inserted before the
  existing "## Persistence") — lifecycle, the `Application.Storage` record-id handshake
  (`lift_live_record`/`lift_pending_record`), the in-flight/never-shrink guards, the silent
  failure policy, the `started_at` timestamp rule, and the last-write-wins caveat.
- `docs/06-sync.md`: added the two new endpoints to the ASCII flow diagram, a new "Live sync: two
  more endpoints next to the write-back above" section documenting the exact request/response
  shapes, the `started_at` header field, the timestamp-stability rule, and the never-shrink guard;
  updated the stale `54 passed` test-count reference to `65 passed`.
- `dist/Liftosaur.prg` + `dist/Liftosaur.prg.sha256` refreshed from this session's
  `linux-build.sh` output (verified the old checked-in sha256 no longer matched a fresh build
  before overwriting — `c172d5c3...` now vs. the prior `76191...`).
- `dist/Liftosaur-beta.iq` rebuilt via `tools/build_beta_iq.sh 4012BE4F-A8B2-421C-87CD-66095EBCBE6F`
  (the SAME beta app id reused, not a new one) and `dist/Liftosaur-beta.iq.sha256` refreshed to
  match. Note: `dist/*.iq` is `.gitignore`d (only `dist/*.prg`/`dist/*.sha256` are the tracked
  "signed release artifacts we hand out" per the gitignore's own comment) — this is a pre-existing
  repo convention, not something changed this session; the `.iq` itself won't show up in `git
  status`, only its `.sha256` sidecar will.

```
cd embedded/monkeyc && HOME=/home/hermes ./tools/build_beta_iq.sh 4012BE4F-A8B2-421C-87CD-66095EBCBE6F
```
Result: `BUILD SUCCESSFUL`, `bin/Liftosaur-beta.iq (420264 bytes)`, manifest restored to the
production app id `9441493B-9C50-48A9-8E21-0416DB9F9F10` afterward (the script does this itself).

All Task 6 gates (pytest, linux-build.sh, verify_watch_payload.py tunnel+localhost) are the same
runs already logged above under Tasks 4/3/5 respectively — not re-run redundantly since no code
changed after those runs; only docs and dist/ artifacts changed afterward.

---

## Task 5 — Off-device proof, then the real cycle (ORCHESTRATOR'S STEP — not run this session)

Plan item 1 (extend `verify_watch_payload.py` with `--live-flow`) and item 2 (assert the new query
params are escaped) were **not implemented** this session — out of scope per the orchestrator's
instructions (scope: Tasks 1-4 and 6 only). The dry-run curl calls under "Manual dry-run
verification" above cover the same create/update/discard shapes by hand instead.

**Plan item 3 — the real create → update → delete cycle against the live Liftosaur account — is
explicitly Hermes' step, not this session's.** Nothing below was run by this agent. Do not run any
of it without dropping `dry_run=1` deliberately and understanding it writes/deletes a REAL record
in the user's training history.

Suggested commands for Hermes to run (adjust program name / day to match a real day in
`dist/plan.json`):

```bash
# 1) create (writes a REAL record - note the returned id)
curl -sS -X POST "https://transcripts-forward-acdbentity-ascii.trycloudflare.com/api/v1/watch/workout/live?payload=<compact-payload-one-set>&record="

# 2) update the SAME record with a second set (use the id from step 1)
curl -sS -X POST "https://transcripts-forward-acdbentity-ascii.trycloudflare.com/api/v1/watch/workout/live?payload=<compact-payload-two-sets>&record=<id-from-step-1>"

# 3) verify via the MCP get_history tool (or the Liftosaur phone app) that exactly one record
#    exists, with both sets, not two records

# 4) delete it (cleanup - must leave nothing behind)
curl -sS -X POST "https://transcripts-forward-acdbentity-ascii.trycloudflare.com/api/v1/watch/workout/discard?record=<id-from-step-1>"

# 5) verify via get_history that the record is gone
```

The Cloudflare tunnel hostname above is read from `~/.liftosaur-tunnel-url` and can change if the
tunnel restarts (docs/06's "sharp edge") — re-check it before running these.

---

## Device protocol for the user (manual verification checklist, once installed)

1. Install the new build (unplug after copying `dist/Liftosaur.prg` to GARMIN/APPS over MTP), open
   the app, **start a workout**.
2. Log **one** set → within a few seconds a new record should appear in Liftosaur (phone app / web)
   with that set. Check it.
3. Log a second set → the same record should grow (not a second record).
4. **Discard** that workout on the watch → the record must disappear from Liftosaur.
5. Then run a normal workout to completion with **Save** → exactly **one** record, containing every
   set, with the right week/day and duration.
6. Report what the phone showed at each step; Hermes verifies the Liftosaur side afterwards with
   `get_history`.

---
