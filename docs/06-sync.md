# 06 — Sync: fetching the plan, writing workouts back

The watch is offline-capable but not offline-only. It talks to **our backend**,
never to Liftosaur directly, so the Liftosaur API key never leaves the server.

```
watch ──https──► backend ──► Liftosaur API
  GET  /api/v1/watch/plan?section=Week%201      compile the current program
  POST /api/v1/watch/workout                    create_history_record
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

The hostname is written to `~/.liftosaur-tunnel-url`.

### ⚠ The one sharp edge

A quick-tunnel hostname is **regenerated every time the tunnel restarts**, and
the watch bakes the URL in at build time (`LIFT_BACKEND` in `source/Comms.mc`).
After a tunnel restart the watch must be rebuilt:

```bash
cd embedded/monkeyc
python3 tools/plan_from_liftosaur.py          # re-bake the plan too
sed -i "s|const LIFT_BACKEND = \"[^\"]*\"|const LIFT_BACKEND = \"$(cat ~/.liftosaur-tunnel-url)\"|" source/Comms.mc
HOME=/home/hermes ./tools/linux-build.sh venu2s
```

**The fix for this is a named tunnel on a domain you own** (`cloudflared tunnel
login`, then a tunnel routed to e.g. `lift.randalls.cc`), which keeps one stable
hostname forever and removes the rebuild step. That needs interactive Cloudflare
auth, so it is left as a deliberate follow-up rather than done silently.

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

Backend tests cover the format exhaustively — `backend/python/tests/test_watch_api.py`
asserts the exact text, the grouping rules, the rejection-vs-success distinction,
the section filter, the dry-run mode, and the compact-payload round-trip for
every day in the plan (`54 passed` as of this writing; `35` as previously
documented here was already stale before this update).
