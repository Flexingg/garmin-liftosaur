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
liftosaur-backend.service   0.0.0.0:8008   the API
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
encoder.

## Verifying sync without the watch

```bash
cd embedded/monkeyc
python3 tools/plan_from_liftosaur.py --post /tmp/test_workout.json   # writes a workout
```

Test against the **real** program name, then delete the record with the
Liftosaur `delete_history_record` tool (it takes the returned id).

Backend tests cover the format exhaustively — `backend/python/tests/test_watch_api.py`
asserts the exact text, the grouping rules, the rejection-vs-success distinction
and the section filter (`35 passed` as of this writing).
