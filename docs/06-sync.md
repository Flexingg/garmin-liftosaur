# 06 — Sync: fetching the plan, writing workouts back

The watch is offline-capable but not offline-only. It talks to **our backend**,
never to Liftosaur directly, so the Liftosaur API key never leaves the server.

```
watch ──https──► backend ──► Liftosaur API
  GET  /api/v1/watch/plan?section=Week%201      compile the current program
  POST /api/v1/watch/workout                    create_history_record (end of workout)
  POST /api/v1/watch/workout/live               create_history_record / update_history_record
  POST /api/v1/watch/workout/discard            delete_history_record
```

Baked into the app as a fallback: `source/PlanData.mc` (see docs/05). If the
network is down the workout still runs, and the plan is simply the last one that
was compiled at build time.

## Why the watch needs https, and why that shaped the design

`Communications.makeWebRequest` **refuses plain http**: the platform returns
`SECURE_CONNECTION_REQUIRED (-1001)`. It is not a warning — the request never
happens. So the LAN address the phone uses (`http://192.168.1.146:8008`) is
unreachable from the watch, and a self-signed certificate would fail validation
too.

The backend is therefore fronted by a **Cloudflare quick tunnel**, which gives a
real, publicly trusted certificate with no account or DNS changes:

```
garmin-liftosaur-backend.service   0.0.0.0:8008   the API
liftosaur-tunnel.service    cloudflared    https://<random>.trycloudflare.com
```

The hostname is written to `~/.liftosaur-tunnel-url` **and published** (2026-09-24)
to `endpoint.json` at the repo root; `liftosaur-tunnel.sh` commits and pushes it
whenever the hostname changes.

### Endpoint robustness (2026-09-24): the watch no longer needs a rebuild

A quick-tunnel hostname is regenerated every time the tunnel restarts (it did on
2026-09-20, `transcripts-forward-acdbentity-ascii` → `them-pda-classifieds-experts`).
The app used to bake one URL in and concatenate it verbatim, so a rotation — or a
`/` or space typed into the settings value — broke every sync until a new `.prg`
was sideloaded. `source/Endpoint.mc` now owns the rules (pure functions, no I/O,
mirrored in `tools/endpoint_mirror.py` and tested by
`backend/python/tests/test_endpoint.py`):

- **`normalizeBaseUrl`** trims whitespace/slashes and requires `https://` (plain
  `http` is only accepted for loopback hosts, because the platform answers
  `-1001 SECURE_CONNECTION_REQUIRED` anywhere else).
- **`joinUrl`** puts exactly one `/` between base and path. This is the fix for
  the trailing-slash bug: `base + "/api/v1/..."` with a base ending in `/` used to
  produce `//api/v1/...` (404) or a path ending in `/` — and **FastAPI answers a
  trailing-slash path with a 307**, which `makeWebRequest` never follows. The same
  trailing-slash URL has been observed answering **307 from one Cloudflare edge and
  200 from another minutes apart**, which is worth knowing before blaming the
  backend for a "3xx": through the tunnel the status is edge-dependent, so the
  only safe answer is to never emit such a URL.
- **Candidates and failover** (`candidates`, `shouldFollow`, `isRetryable`,
  `nextIndex`): the watch tries, in order, the base URL that last worked
  (Storage), the `backendUrl` runtime property, then the compiled `LIFT_BACKEND`.
  Anything that is not a 2xx moves on to the next one — including Garmin Connect
  Mobile's **`-300`**, which is *not* an HTTP status but CIQ's undocumented
  "network request timed out", i.e. what a dead tunnel hostname looks like from
  the wrist. A 3xx is additionally retried once as-is before failing over.
- **Discovery**: only after every candidate has failed, the watch fetches
  `LiftEndpoint.DISCOVERY_URLS` (raw.githubusercontent → jsDelivr, both serving
  `endpoint.json`) and re-sends the failed request against the hostname found
  there. That makes a tunnel rotation self-healing instead of a sideload.

Diagnostics on the wrist: the day picker's hold menu and the workout options menu
now have **"Sync status"** — the effective base URL, the last failure in words
(`-300 network timeout (phone)`, `307 redirect`, …), the pending-retry state, and
a **"test endpoint"** probe (`GET /api/v1/watch/health`) that answers even when
Liftosaur itself is down.

**A named tunnel on a domain you own** (`cloudflared tunnel login`, routed to e.g.
`lift.randalls.cc`) is still the permanent fix — one stable hostname, no discovery
needed. It requires interactive Cloudflare auth, so it remains a deliberate
follow-up rather than something done silently.

## The plan endpoint

`GET /api/v1/watch/plan` returns the compiled plan (docs/05 explains the
compilation). `?section=Week%201` filters to one week-block, which halves the
payload — 8.9 KB instead of 15.6 KB — because the response travels to the phone
and then over BLE to the wrist.

- `503` = Liftosaur unreachable → the watch keeps using its baked-in plan.
- `404` = unknown section → deliberately *not* an empty plan, so a typo cannot
  silently wipe the watch's day list.

The plan is cached in-process for 10 minutes, so opening the app repeatedly does
not hammer the Liftosaur API.

## Writing workouts back

`POST /api/v1/watch/workout` takes the flat set list and renders a Liftoscript
*history* record:

```
2026-09-13T08:06:14Z / program: "5/3/1 BBB - Squat/Bench/Deadlift/OHP" / dayName: "Day 1" \
  / week: 1 / dayInWeek: 1 / duration: 4200s / exercises: {
  Squat / 1x5 220lb, 1x5 250lb, 1x6+ 285lb, 1x10 170lb
  Romanian Deadlift, Barbell / 1x8 135lb
}
```

Runs of identical sets collapse (`5x10 170lb`), while an ascending 5/3/1 wave
stays separate — `3x5 220lb` would be a lie. AMRAP sets carry `+`.

### Two failures worth knowing about

**Liftosaur rejects a record whose program name does not exist**, and it does so
as *content* with a `200`, not as an error:

```
Program "Liftosaur Watch TEST - ignore" not found. Use list_programs...
```

The first version of the endpoint reported `recorded: true` for that. It now
parses the response and only reports success when Liftosaur returns a record id
(`{"id":1789286774000,...}`), returning `502` otherwise. That matters: a false
success means the user believes their session was saved when it was discarded.

The watch therefore sends the **real program name** — `LiftPlan.program()` when
offline, or the `program` field of the fetched plan.

**A failed upload is never lost.** If the POST fails (no signal in the gym), the
workout is stashed on the watch and retried on the next launch
(`LiftComms.retryPending`). It is stored as a compact string because
`Application.Storage` cannot hold nested dictionaries and the runtime has no JSON
encoder. The stash key is `lift_pending_workout_v2` (bumped 2026-09-18, see below
— the `v1` key is deliberately abandoned and never read again).

### What went wrong: the `%00` encoder regression (2026-09-18)

Commit `d084048` ("Fix the save crash for real (no POST body)") introduced
`Comms.urlEncode()` to escape the workout payload for the query string, but it
called `.toNumber()` on a **1-character String** instead of a **`Char`**:

```monkeyc
var code = ch.toNumber();            // "/".toNumber()  -> null   ("5".toNumber() -> 5)
var v = (code == null) ? 0 : code;   // -> 0
out += "%" + hex(...v...);           // -> "%00"  = a NUL byte
```

`String.toNumber()` parses a *number*, not a code point — it returns `null` for
anything that isn't a numeral, which silently fell back to `0`. So every `|`,
`;` and `/` in the payload was transmitted as `%00` instead of `%7C`/`%3B`/`%2F`.
The live backend log for the user's actual save attempts showed it:

```
POST /api/v1/watch/workout?payload=Day%203%00Week%201%005%003%001%20BBB%20-%20Squat%00Bench%00Deadlift%00OHP%00...
                                                                        ^^^^ all separators are NUL
... HTTP/1.1" 422 Unprocessable Entity
```

`watch_api.parse_compact()` splits on `|`/`;`; with NULs it found one header
field and raised `422 malformed payload header`. The **previous** build (before
`d084048`) posted correctly at 15:39:58 the same day
(`...Day%202%7CWeek%202%7C5%2F3%2F1%20BBB... HTTP/1.1" 200 OK`), confirming this
was a regression in that one commit, not a flaw in the query-string design.

Fixed 2026-09-18: `urlEncode()` now builds code points from `String.toCharArray()`
/ `Char.toNumber()`, which never falls back to a numeral parse. RFC 3986:
`A-Z a-z 0-9 - . _ ~` pass through unescaped; everything else becomes `%XX`.
Never emits `%00` for a reserved character again (see the mutation proof in
`tools/verify_watch_payload.py`, which copies the encoder and deliberately
breaks it to prove the check itself can fail).

A secondary bug rode along with this one: `Comms.onPostResponse()` stashed a
failed payload for retry but never cleared it on success, so once anything had
been retried, every later `postWorkout()` re-sent the stale stashed workout and
the new one was silently never uploaded. `WorkoutController.clearPending()` is
now called both on a successful post and at the start of every `startWorkout()`,
and the stash key was bumped to `_v2` so any 422-era stash (which would replay
today with a ~7.5-hour garbage duration — see docs/05) is simply abandoned
rather than migrated.

## Live sync: two more endpoints next to the write-back above

`POST /api/v1/watch/workout/live` and `POST /api/v1/watch/workout/discard`
push the workout to Liftosaur **while it is happening**, one push per
completed set, rather than only at the end. See docs/05's "Live sync"
section for the full lifecycle, the `Application.Storage` record-id
handshake, and the guards. In brief:

```
POST /watch/workout/live?payload=<compact>&record=<id or "">&dry_run=<0|1>
    record == ""  -> create_history_record, returns the new id
    record set    -> update_history_record({"id": record, "text": <full text>})
                     (a rejected update - the record is gone - falls back to
                     create, so the workout is never lost)
    dry_run=1     -> renders the text, never calls Liftosaur

POST /watch/workout/discard?record=<id>&dry_run=<0|1>
    record == ""  -> {"deleted": false, "reason": "no record"} (not an error)
    otherwise     -> delete_history_record({"id": record})
                     ("not found" is reported as deleted:true, reason:
                     "already gone" - the user's intent is already satisfied)
    dry_run=1     -> never calls Liftosaur
```

The compact payload gains an **optional 5th header field**, `started_at`
(unix seconds, the watch's wall-clock session start):
`day|section|program|duration_s|started_at;exercise|weight|reps|amrap;...`.
A 4-field header (no `started_at`) still parses exactly as before - the
end-of-workout post and any pre-existing stash keep working unchanged.

`to_liftohistory()` gained a `stamp` parameter: when given, it overrides
`finished_at`/`now()`, which is how a live record's date stays **fixed at the
session start** across every update instead of creeping forward with each
push. Priority order: the payload's `started_at` (stable across a backend
restart), then a stamp the backend remembered in memory when the record was
created, then `now()` as a last resort (which can shift a record's date once
if the service restarted mid-session and the watch sent no `started_at`).

**Never shrink a live record.** The backend keeps an in-memory
`{record_id: highest_set_count_written}` map. A push carrying fewer sets than
the last one already applied for that record is a late/out-of-order request,
not real progress - it is refused (`{"skipped": "stale"}`) rather than
overwriting the record with less data than it already has.

Both endpoints share `watch_workout`'s rejection-vs-success discipline: a
write is only reported as successful when Liftosaur's response is a JSON
object carrying an `id`; anything else is a `502`, never a false success.

### Live sync in Liftosaur's own terms (2026-09-24)

The live path is not only a history record: `/watch/workout/live` also drives
Liftosaur's **active workout** through its REST API (`/api/v1/workout/start`,
`/workout/sets`, `/workout/finish`, `/workout/current`), authenticated by the
same API key. That matters because `ApiV1_startWorkout` writes
`user.storage.progress[0]` (`lambda/utils/apiv1Workout.ts` upstream) — the exact
slot the phone app's live-workout view reads — and every write ends in
`UserDao.applyStorageUpdate` → `PushSync_notify`, i.e. a silent push telling the
user's *other* devices to re-pull storage. So the watch's sets reach the phone
without any polling, and a workout begun on the phone is adopted rather than
duplicated (`409 workout_already_active` comes back for a *different* one).

Two things in that path were wrong and are fixed:

- **One request per set.** The loop logged each set with its own
  `POST /workout/set`; by the twentieth set a single watch push meant twenty
  sequential round trips to liftosaur.com, comfortably past the ~10-20 s timeout
  Garmin Connect Mobile applies to a `makeWebRequest` — which the watch reports
  as `-300`. It is now one `POST /workout/sets` batch carrying only the sets not
  already applied.
- **Appended set ids.** A set beyond the plan's list was appended with
  `secrets.token_hex(3)`, which can contain digits; Liftosaur validates a new
  `setId` against `^[a-z]{6}$` and answers `400 invalid_input`, killing the live
  sync for the rest of the session. `plan.new_set_id()` now mints six lowercase
  letters.

Everything a live write reports is **surfaced, never swallowed**: the response
carries `rest_synced` and `rest_error`, and a failure also logs a warning
(`journalctl --user -u garmin-liftosaur-backend`) and sets the watch's sync note.

**Identity rules for finish/discard.** A workout's identity in Liftosaur is its
`startTime` (that value becomes the history record's id on finish), so the watch's
finish and discard actions act only on a workout with a matching `startTime`. A
workout started by another device is left alone and reported
(`a different workout is in progress (started …, this session is …)`) — before
this, the backend sent its own guess, got `404`, swallowed it, and the workout
stayed open in the app while the watch said it had been saved/discarded.

### `GET /api/v1/watch/health`

Liveness only: it answers `200` without touching Liftosaur, because "is the
configured backend URL reachable?" and "can the backend reach Liftosaur?" are
different failures with different fixes, and it is the first one that a rotated
tunnel hostname breaks. `GET /api/v1/watch/plan?program=<bad-id>` answers `404`
(unknown program) and `?program=<id>/` is stripped rather than reaching Liftosaur
as a name with a slash in it (that used to be a `500`, because Liftosaur's plain
text "not found" reply was fed to `json.loads`).

## Verifying sync without the watch

```bash
cd embedded/monkeyc
python3 tools/verify_watch_payload.py                       # dry-run against the tunnel by default
python3 tools/verify_watch_payload.py --backend http://127.0.0.1:8008
```

This mirrors the watch's exact compact-payload format and (fixed) `urlEncode()`
in Python, checks every day in `dist/plan.json` for `%00`/length, and POSTs with
`?dry_run=1` — the backend renders the Liftohistory text and reports it **without
writing to Liftosaur** (`{"recorded": false, "dry_run": true, ...}`). The tool
refuses to trust a response that doesn't explicitly confirm `dry_run: true`,
because a backend process that predates the `dry_run` parameter silently ignores
it and performs a real write — this happened once during development. `--live`
exists for an end-to-end real write but must only be run with explicit sign-off;
it is never part of routine verification.

For a real write, use `plan_from_liftosaur.py --post` instead:

```bash
python3 tools/plan_from_liftosaur.py --post /tmp/test_workout.json   # writes a workout
```

Test against the **real** program name, then delete the record with the
Liftosaur `delete_history_record` tool (it takes the returned id).

### The end-to-end proof tool

```bash
cd embedded/monkeyc
python3 tools/e2e_watch_sync.py         # 25 assertions, over the real tunnel
```

It goes through the public tunnel URL — the same path a watch request takes — and
proves, in order: the health probe; the URL shapes (the app's own, and the
trailing-slash one that used to 500); a set logged live reaching Liftosaur's
active workout **with the watch session's own `startTime`**; the second set
updating the same workout; a discard removing both; and a finished workout
landing as a history record which it then **reads back from the Liftosaur API**
and deletes again. It refuses to start if a workout is already in progress (it
must never adopt someone else's session), and it cleans up after itself — nothing
is left in the account.

It deliberately does **not** exercise the REST *finish* leg
(`POST /workout/finish`), because that advances the program to the next day: on a
real account a fake finish would corrupt the owner's progression. That leg is unit
tested instead (identity match → `workout_finish(start_time=<the workout's own>)`),
and the leg is exercised for real the first time he finishes a workout with the
watch — watch the sync line and the Liftosaur history.

Backend tests cover the format exhaustively — `backend/python/tests/test_watch_api.py`
asserts the exact text, the grouping rules, the rejection-vs-success distinction,
the section filter, the dry-run mode, the compact-payload round-trip for every
day in the plan, and (as of the live-sync addition) the create/update/stale/
discard/dry-run behaviour of the two endpoints above. `tests/test_endpoint.py`
covers the endpoint rules the watch uses, against the Python mirror of
`Endpoint.mc` (`178 passed` in total as of 2026-09-24; `54` was the pre-live-sync
baseline).

**The suite is hermetic** (`tests/conftest.py`, 2026-09-24). Before that guard it
was not: the live-sync tests stubbed `plan.mcp_call` but the live endpoint also
calls the Liftosaur **REST** API, so running `pytest` reached liftosaur.com for
real and **started a phantom workout in the owner's account** — with the tests'
own weights in it — which then sat there as "in progress" until something
discarded it. `conftest.py` replaces `plan.rest_call` with a refusal for every
test; a test that needs the REST leg patches `plan.workout_*` itself.
