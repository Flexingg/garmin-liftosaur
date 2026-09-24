# 2026-09-24 — the "sync 300" transport failure, the endpoint work, and the phone+watch question

Owner's report, in his words:

1. "Consistent sync 300 errors when logging."
2. "Not syncing live to Liftosaur where I can do it on my phone and my watch at
   the same time."
3. "It's not even saving to the Liftosaur app after I complete, but it is saving
   to Garmin."

This pass fixed the transport (1 and 3), answered (2) properly with evidence, and
found two further bugs nobody had reported yet.

---

## 1. What "300" actually is — and what it is not

**`-300` is not an HTTP status.** It is Connect IQ / Garmin Connect Mobile's
*undocumented* "network request timed out" code, in the same family as `-104`
(phone offline) and `-1001` (secure connection required). Garmin's own developer
forum is the only public documentation
(`forums.garmin.com/developer/connect-iq/.../5230` and `.../7433`): a user
measures "response code `-300`" with the phone connected but without data, and
another thread titles the problem "makeWebRequest fails with response code -300
on Android". So the owner's "300 errors" are the *phone's* HTTP request to the
configured URL timing out — a transport failure, not a server response.

A genuine 3xx is also fatal, for a different reason: `makeWebRequest` does not
follow redirects, so any 3xx reaches the app as a failure. Both routes were
hunted down with evidence.

### Evidence: every URL the app calls, tested from this machine

The app calls our backend only (never Liftosaur), six URLs:

| # | URL (base + path) | today, through the tunnel |
|---|---|---|
| 1 | `GET /api/v1/watch/programs` | 200 |
| 2 | `GET /api/v1/watch/plan?program=<id>` | 200 |
| 3 | `GET /api/v1/watch/exercise?name=<name>` | 200 |
| 4 | `GET /api/v1/watch/workout/current` | 200 |
| 5 | `POST /api/v1/watch/workout/live?payload=…&record=…[&finished=1]` | 200 |
| 6 | `POST /api/v1/watch/workout/discard?record=…` | 200 |

Nothing in the app's own URL shapes returns a 3xx. What *does* is a
trailing-slash variant, and that is the smoking gun for a misconfigured base URL:

```
GET  /api/v1/watch/programs/                 -> 307  location: /api/v1/watch/programs
POST /api/v1/watch/workout/live/             -> 307  location: /api/v1/watch/workout/live
GET  /api/v1/watch/plan?program=gjedbyiv/    -> 500  (Liftosaur answered the plain text
                                                     "Program 'gjedbyiv/' not found",
                                                     which json.loads() then choked on)
```

An unnormalised base URL is exactly how the app produces those: it used to
concatenate `base + "/api/v1/..."` with whatever the `backendUrl` setting held, so
a value ending in `/` yields `//api/...` (404) or a trailing-slash path (307).
**And through Cloudflare the status for the same trailing-slash URL is
edge-dependent**: one call returned `HTTP/1.1 307`, and minutes later the same URL
returned `200` — Cloudflare normalises it on some edges and not others. A status
that changes by edge is the worst possible thing for a client that cannot follow
redirects, and it is why the fix is "never emit such a URL".

### Evidence: the requests never reached the backend

The backend logs every request (`journalctl --user -u garmin-liftosaur-backend`).
From the 2026-09-20 rebuild until today there were **no watch requests at all** —
only a handful of scanner probes (`HEAD /`) — while the last live syncs (Sep 19,
before the tunnel rotated at 13:36 on Sep 20) are there in full, every one a
`200 OK`:

```
Sep 19 05:03:17 python[1622923]: "POST /api/v1/watch/workout/live?payload=Day%204%7C…&record=1789801063000&finished=1 HTTP/1.1" 200 OK
```

The quick tunnel rotated on 2026-09-20 13:36 EDT
(`transcripts-forward-acdbentity-ascii` → `them-pda-classifieds-experts`) — it is
in the tunnel's journal — and the app was rebuilt with the new hostname 7 minutes
later. A watch still running a build baked with the old hostname cannot resolve it
(checking from here: the dead hostname answers **HTTP 530**/"Argo Tunnel error"
when it resolves at all), and from the wrist that failure is `-300`. That is the
consistent, every-time failure he saw, and it explains both 1 and 3: a dead
transport kills the per-set live sync *and* the end-of-workout save, while the
Garmin FIT path (no network) still works.

**Not verified:** which build is on the watch. Nothing in the account or the logs
can tell us; the watch was not connected during this pass.

---

## 2. What changed, and why it cannot recur silently

**Watch: `source/Endpoint.mc` (new, pure).** `normalizeBaseUrl` (trim, require
https, loopback-only exception for http), `joinUrl` (exactly one `/`), `candidates`
(learned → configured → baked), `shouldFollow` (3xx), `isRetryable` (everything
that is not a 2xx, negative codes included), `nextIndex`, `describeCode`
(`-300` → "network timeout (phone)"), `parseDiscovery`.

**Watch: `Comms.mc`.** Every URL is now built in one place (`dispatch` →
`LiftEndpoint.joinUrl`). A non-2xx fails over to the next candidate base URL (a
3xx is retried once as-is first); when all candidates fail, the app fetches
`endpoint.json` from `raw.githubusercontent.com` (then jsDelivr) and re-sends
against the hostname found there — so a rotated tunnel is self-healing instead of
needing a sideload. The base that answered is remembered in `Application.Storage`
and tried first next time. Failures are reported, not swallowed: `lastErrorText`,
`probeText`, and a live-sync failure now sets the sync note instead of only a log
line.

**Watch: `SyncStatusView` + menu entries.** Day picker (long-press) and workout
options both offer **"Sync status"**: base URL in use, candidate count, last
failure in words, probe result, pending-retry state, Garmin activity note, and a
**test endpoint** probe (`/api/v1/watch/health`).

**Tunnel: `~/.hermes/scripts/liftosaur-tunnel.sh`.** Publishes the current
hostname to `endpoint.json` in this repo (commit + push, best-effort, only that
file) whenever it changes. Tested against a scratch repo: it writes valid JSON,
commits only on a real change, pushes, and does not touch anything else.

**Backend.**
- `GET /api/v1/watch/health` (new): liveness only, never calls Liftosaur.
- `/watch/plan`: `program`/`section` are stripped of whitespace and slashes;
  an unknown program is `404` (was `500` via a `JSONDecodeError` on Liftosaur's
  plain-text "not found").
- `_sync_live_to_liftosaur`: one **batch** `POST /workout/sets` instead of one
  request per set (a 20-set push meant 20 sequential round trips — past GCM's
  timeout, i.e. a self-inflicted `-300`); appended ids are six lowercase letters
  (`^[a-z]{6}$`, `secrets.token_hex(3)` could contain digits and was rejected with
  `400`); the result is returned as `rest_synced`/`rest_error` and logged, never
  swallowed.
- finish/discard act only on a workout whose `startTime` matches this session's,
  and report when it does not (`a different workout is in progress (started …)`).

---

## 3. Two bugs found while proving it (not in the owner's report)

**a) The test suite was writing to his live account.** The live-sync tests stubbed
`plan.mcp_call` only, but `/watch/workout/live` also calls the Liftosaur REST API:
`workout_get_current()` → `workout_start()`. Running `pytest` therefore **started
a phantom workout in his account on every run**, with the tests' own weights in it
(220/250/285 lb), and it sat there as "in progress" until something discarded it.
Ablation: the plain suite leaves `startTime=…` active; with a network trap
installed, nothing is created.

```
== A: plain suite ==         176 passed → state after: active workout startTime=1790241099000, 3 sets
== B: with the trap ==       176 passed → state after: no active workout
```

Fixed with `backend/python/tests/conftest.py`: an autouse fixture replaces
`plan.rest_call` with a refusal, so the suite is hermetic (and ~4× faster).

**b) Discard/finish lied when the identity did not match.** Both used their own
guess for the workout's `startTime` (the record id / the payload stamp). When the
workout had been started by another device (or by a crashed session), Liftosaur
answered `404 No workout in progress with startTime …`, the code swallowed it, and
the watch reported a successful discard/save while the workout stayed open in his
app. Now they check identity first and say so.

---

## 4. Proof, end to end, over the real tunnel

`tools/e2e_watch_sync.py` — 25 assertions, all passing, run twice (`25 passed,
0 failed`). It goes through the public tunnel URL, i.e. the same path a watch
request takes, and it cleans up after itself. Highlights:

```
[0]  GET /api/v1/watch/health -> 200 {'status': 'ok', 'service': 'garmin-liftosaur'}
[1]  POST /watch/workout/live (set 1) -> 200  id=1790241295000 rest_synced=True
     active workout: startTime=1790241295000 dayName='Week 1 - Day 1' ['Squat:1']
     PASS the workout's startTime is the watch session's stamp
     PASS set 1 is visible with the watch's weight -> ['220lb']
[2]  POST /watch/workout/live (set 2) -> 200  {'updated': True, 'rest_synced': True}
     PASS both sets are in Liftosaur's active workout -> ['220lb', '250lb']
[3]  POST /watch/workout/discard -> 200 {'deleted': True, 'rest_discarded': True}
     PASS the active workout is gone again (null)
[4]  POST /watch/workout/live?finished=1 -> 200  id=1790241870000
     READ BACK FROM LIFTOSAUR:
       2026-09-24 09:24:30 +00:00 / program: "5/3/1 BBB - Squat/Bench/Deadlift/OHP" / dayName: "Day 1"
       / week: 1 / dayInWeek: 1 / duration: 1200s / exercises: {
         Squat / 1x5 285lb
         Bench Dip / 1x8 35lb
       }
     PASS it carries the watch's sets / PASS it is marked finished
[5]  DELETE /history/<id> -> 200 {'deleted': True}
     PASS the test record is gone
```

**What that does and does not prove.** The *backend half of the watch's path* is
proven: payload → parse → Liftohistory → Liftosaur → read back, plus the live
REST workout. The *wrist half* (Monkey C) is compile-verified and unit-tested
against its Python mirror, but only a real sideload can confirm it on hardware.
The REST **finish** leg is deliberately not exercised end to end: `POST
/workout/finish` advances the program to the next day, and a fake finish would
corrupt his progression. Its identity rule is unit-tested instead.

---

## 5. The phone + watch question, re-checked

The old verdict ("impossible through this API") is **out of date**, and the
evidence is now concrete:

- Liftosaur's REST API v1 has first-class workout endpoints:
  `/api/v1/workout/start|current|set|sets|finish|next` (`lambda/api/v1.ts`
  upstream), authenticated by **the same API key this backend holds**.
- `ApiV1_startWorkout` writes `user.storage.progress[0]`
  (`lambda/utils/apiv1Workout.ts`) — the slot the phone app's live view reads
  (`state.storage.progress?.[0]`).
- Every such write ends in `UserDao.applyStorageUpdate` →
  `PushSync_notify(...)` (`lambda/dao/userDao.ts:716`): a **silent push** telling
  the user's other devices to re-pull storage.
- Verified live: `POST /workout/start` → `GET /workout/current` showed the
  workout with entries; `POST /workout/set` logged a set; `GET` read it back;
  `DELETE` removed it. Through our own endpoint, the e2e above shows the same.

So the watch and the phone can work on the same workout: the backend adopts an
already-active workout (Liftosaur answers `409 workout_already_active` only for a
*different* one) and matches exercises by name, and the phone is notified by push.

**What is still not guaranteed**, stated plainly:
- The phone app's live UI is driven by its own engine and merges storage with
  per-field version vectors; whether an *open, mid-workout* phone screen updates
  from a pushed external write cannot be verified without his phone. He can test
  it in one minute: start a workout on the phone, log one set on the watch, look
  at the phone.
- Silent pushes are best-effort on Android; his ColorOS build is aggressive about
  background work, so an update may only arrive when the app is next opened.
- Whoever starts the session owns its identity; the watch will not finish or
  discard a session another device started (it reports it).

---

## 6. Gates

```
cd backend/python && .venv/bin/python -m pytest tests/ -q
    178 passed, 1 warning in 2.72s

cd embedded/monkeyc && HOME=/home/hermes ./tools/linux-build.sh venu2s
    BUILD SUCCESSFUL
    Built bin/Liftosaur.prg (258588 bytes) target=006-B3704-00
    check-device-api: all 78 module calls exist on 'venu2s'

python3 embedded/monkeyc/tools/endpoint_mirror.py --mc embedded/monkeyc/source/Endpoint.mc
    endpoint_mirror: in lockstep with embedded/monkeyc/source/Endpoint.mc
```

Only one build warning remains, and it is pre-existing (`WorkoutUi.mc:1017
InfoDelegate._c is not used` — untouched code). Two warnings introduced by this
pass were fixed rather than left: a "statement is not reachable" on the
`&finished=1` path (now keyed off the request kind instead of a dictionary lookup
— that flag is the difference between a saved workout and one that stays "in
progress" forever) and two never-read diagnostic fields.

**Mutation proof** (`/tmp/mutation_proof.sh`, run on copies in `/tmp` only — no
`git checkout --`):

| mutation | result |
|---|---|
| `shouldFollow()` → always `False` | 4 failed (`301/307/308` + `follow_boundaries`) |
| `nextIndex()` → always `-1` | 1 failed (`test_next_index`) |
| `isRetryable()` → only 5xx | 11 failed |
| restored | 94 passed each time |

---

## 7. Delivered

- `embedded/monkeyc/bin/Liftosaur.prg` = `dist/Liftosaur.prg`,
  258 588 bytes, sha256 `cd1a75c1052941347535f11cea5fcccd7cfee5905eb13f2bd24a6b716a0d1c4b`
  (built with the repo's own `tools/linux-build.sh venu2s`).
- LAN copy `Liftosaur-lifto-2026-09-24.prg` in `/home/hermes/healthos-apk/`
  (served by `healthos-apk.service` on :4310) — verified byte-identical over HTTP
  (`http=200`, same 258 588 bytes, same sha256).
- GitHub release `lifto-2026-09-24` on `Flexingg/garmin-liftosaur`.

## 8. What needs him

1. **Sideload the new `.prg`** (MTP → `GARMIN/APPS`, then physically unplug). His
   watch is almost certainly still running a build with the dead 2026-09-20-rotated
   hostname; that alone accounts for "consistent 300 errors" and the workout never
   reaching Liftosaur.
2. Nothing else to configure: the URL is baked in correctly and can now be changed
   from Garmin Connect's App Settings ("backendUrl") without a rebuild. If a sync
   ever fails again, **long-press SELECT → Sync status** says which URL it is
   using and why it failed, and the watch will find a rotated hostname by itself.
3. When he next finishes a real workout: the summary must read `synced to
   Liftosaur`, and the record must appear in the Liftosaur history (that is the
   path the fake-finish restriction kept us from proving here).
4. Optional permanent fix: a **named** Cloudflare tunnel on a domain he owns would
   remove the rotation entirely (needs his interactive `cloudflared login`).
