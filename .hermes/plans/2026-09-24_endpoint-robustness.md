# Plan — endpoint robustness for the Garmin Liftosaur watch app (2026-09-24)

## Diagnosis (already established, do not re-derive)
The watch reaches the backend as: watch → BLE → Garmin Connect Mobile (phone) → HTTPS →
`https://<random>.trycloudflare.com` (cloudflared QUICK tunnel) → FastAPI on :8008.

Two transport faults make every sync fail with what the owner reports as "300 errors":

1. **The base URL is used verbatim.** `Comms.mc` `backendUrl()` returns the
   `backendUrl` runtime property (or the compiled `LIFT_BACKEND`) with no
   normalization, and every call site string-concatenates `base + "/api/v1/..."`.
   A trailing `/` or a stray space in the property gives `//api/v1/...` (404) or a
   malformed URL; FastAPI answers any trailing-slash path with **307**, and
   `makeWebRequest` does NOT follow redirects, so it surfaces as a failure.
2. **The quick-tunnel hostname rotates on every restart** (it did on 2026-09-20
   13:36 EDT, from `transcripts-forward-acdbentity-ascii` to
   `them-pda-classifieds-experts`). A watch running a build baked with the old
   hostname cannot resolve/reach it and Garmin Connect Mobile reports CIQ's
   undocumented **-300 = "network request timed out"**. Verified: no request from
   the watch's network has reached the backend since the 2026-09-20 rebuild,
   while a stale tunnel hostname still resolving returns HTTP 530.

So: normalize + validate the base URL, fail over between candidate base URLs,
follow a 3xx by retrying against the canonical URL, self-heal the rotated hostname
by discovering the current one from a stable JSON document, and make the endpoint
state visibly diagnosable on the watch.

## Files YOU own (touch nothing else)
- CREATE `embedded/monkeyc/source/Endpoint.mc`
- MODIFY `embedded/monkeyc/source/Comms.mc`
- MODIFY `embedded/monkeyc/source/WorkoutUi.mc`
- MODIFY `embedded/monkeyc/source/Workout.mc` (minimal, listed below only)
- CREATE `embedded/monkeyc/tools/endpoint_mirror.py`
- CREATE `backend/python/tests/test_endpoint.py`

Do NOT touch `backend/python/app/*.py`, other test files, docs, PROGRESS*.md —
another worker is editing those in this same working tree right now.

Monkey C facts for SDK 9.2 (`venu2s`): `Lang.String` has **no `trim()` and no
`replace()`** (only compareTo/equals/find/hashCode/length/substring/toCharArray/
toLower/toUpper/toNumber/toDouble/toFloat/toString/toUtf8Array). `Lang.Array` has
add/addAll/indexOf/remove/removeAll/reverse/slice/size/sort/toString. `Lang.Number`
has abs/compareTo/format/... `Lang.Dictionary` has get/hasKey/isEmpty/keys/put/
remove/size/values. There is no `startsWith` — use `substring(0, n).equals(...)`.
Write these files to compile first time; the orchestrator runs the real build.

## 1. `Endpoint.mc` — new, pure (Lang only, no I/O, no Toybox)
`module LiftEndpoint`, with `const DISCOVERY_URLS` (Array<String>, in order):

1. `"https://raw.githubusercontent.com/Flexingg/garmin-liftosaur/main/endpoint.json"`
2. `"https://cdn.jsdelivr.net/gh/Flexingg/garmin-liftosaur@main/endpoint.json"`

and `const HEALTH_PATH = "/api/v1/watch/health";`

Functions:
- `stripEdges(s as String) as String` — drop leading/trailing spaces, tabs and `/`.
- `normalizeBaseUrl(raw as String or Null) as String`
  - `null`/empty → `""`; strip edges; `""` → `""`
  - must start with `https://` (case-insensitive; return the input with the rest
    unchanged, i.e. do not silently re-case the host) — else, if it starts with
    `http://` and the remainder starts with `127.0.0.1` or `localhost`, accept it
    as-is (CIQ allows plain http only there); anything else → `""` (the platform
    returns -1001 SECURE_CONNECTION_REQUIRED for plain http elsewhere).
  - any space inside the remainder → `""`.
- `joinUrl(base as String, path as String) as String` — `""` when base is `""`;
  exactly one `/` between them; a `path` already starting with `/` must not
  produce `//`.
- `candidates(learned as String or Null, configured as String or Null, baked as String or Null) as Array<String>`
  — normalize each, drop `""`, dedupe, keep order: learned, configured, baked.
- `shouldFollow(code as Number) as Boolean` — `300..399` (a redirect
  makeWebRequest refuses to follow).
- `isRetryable(code as Number) as Boolean` — `true` for anything that is not
  `200..299` (3xx, 4xx, 5xx, and negative CIQ/GCM transport codes incl. `-300`).
- `nextIndex(current as Number, count as Number) as Number` — `current + 1` when
  `< count`, else `-1` (candidates exhausted).
- `describeCode(code as Number) as String` — exact strings:
  `200..299` → `"ok"`; `300..399` → `<code> + " redirect"`;
  `400..499` → `<code> + " rejected"`; `500..599` → `<code> + " server error"`;
  `-300` → `"network timeout (phone)"`; `-1001` → `"https required"`;
  `-104` → `"phone offline"`; `-101` → `"no connection"`; `-2` → `"network error"`;
  any other negative → `"network error " + code`; `0` → `"not tried"`.
- `parseDiscovery(data as Dictionary or String or Null) as String` — read
  `"backend"`, return `normalizeBaseUrl` of it when it is a String, else `""`.
  The document shape is `{"backend": "https://<host>.trycloudflare.com"}`.

## 2. `Comms.mc`
Replace raw string concatenation with one dispatch path, and add failover:

- New storage key `const BACKEND_KEY = "lift_backend_learned";` (the last base URL
  that actually worked).
- `initialize()`: `_kinds` is not needed; add fields `_cands` (Array<String>),
  `_candIdx` (Number), `_lastCode`, `_lastKind`/`_lastPathText`, `_probeOk`,
  `_probeCode`, `_probeDone`, `_discoveryTried`.
  `_cands = LiftEndpoint.candidates(Storage[BACKEND_KEY], property backendUrl, LIFT_BACKEND)`;
  `_candIdx = 0`.
- `function baseUrl() as String` — `_cands` empty → `LIFT_BACKEND`, else
  `_cands[_candIdx]` (clamped).
- `private function pathFor(kind as String, extra as Dictionary or Null) as String`
  — returns the path for each kind, using `urlEncode()` as today:
  `"programs"` → `/api/v1/watch/programs`;
  `"plan"` → `/api/v1/watch/plan?program=` + urlEncode(extra["program"]);
  `"exercise"` → `/api/v1/watch/exercise?name=` + urlEncode(extra["name"]);
  `"current"` → `/api/v1/watch/workout/current`;
  `"live"` → `/api/v1/watch/workout/live?payload=` + urlEncode(extra["payload"]) + `&record=` + urlEncode(extra["record"]) (+ `&finished=1` when `extra["finished"]` is true);
  `"discard"` → `/api/v1/watch/workout/discard?record=` + urlEncode(extra["record"]);
  `"health"` → `LiftEndpoint.HEALTH_PATH`.
- `private function dispatch(kind as String, extra as Dictionary or Null) as Void`
  — `Communications.makeWebRequest(LiftEndpoint.joinUrl(baseUrl(), pathFor(kind, extra)), null, {method GET, responseType JSON}, method(:onResponse))`, and it must record `_lastKind`/`_lastPathText` so a failure can be described. Keep the per-kind response handling in ONE callback that switches on `_pendingKind` (store the kind of the in-flight request in a field, since the callback cannot take arguments — `onResponse(code, data)`), then delegates to the existing per-kind logic (`onPrograms`, `onPlan`, `onExerciseInfo`, `onCurrentWorkout`, `onLive`, `onPost`, `onDiscard`, `onHealth`).
- `private function failover(kind as String, extra, code as Number) as Boolean`:
  remember `_lastCode = code`; if `LiftEndpoint.isRetryable(code)`:
  - if there is another candidate (`nextIndex` != -1) → advance `_candIdx`, re-`dispatch` the same kind/extra, return true;
  - else if `!_discoveryTried` → `discover(kind, extra)` (see below) and return true;
  - else surface the failure (set the sync note when it was a user-visible op) and return false.
  On any 2xx: `Application.Storage.setValue(BACKEND_KEY, baseUrl())` and reset
  `_discoveryTried = false`.
- `private function discover(kind as String, extra, idx as Number)` — GET
  `LiftEndpoint.DISCOVERY_URLS[idx]`; on failure try `idx + 1` while in range;
  on success `LiftEndpoint.parseDiscovery(data)`; when non-empty: insert it at the
  FRONT of `_cands` (dedupe), persist it to `BACKEND_KEY`, set `_candIdx = 0`,
  `_discoveryTried = true`, and re-`dispatch(kind, extra)` the original request
  once. A discovery result equal to a URL already in `_cands` must not be
  inserted twice. Discovery is only ever attempted AFTER all candidates failed,
  at most once per app run (`_discoveryTried`), and it must never block the UI.
- `probeEndpoint()` — `dispatch("health", null)`; the health callback sets
  `_probeOk`/`_probeCode`/`_probeDone` and calls `WatchUi.requestUpdate()` so the
  status screen refreshes; it must NOT touch the sync note.
- Diagnostics accessors used by the UI:
  `function endpointText() as String` (base currently in use),
  `function candidateCount() as Number`, `function lastCode() as Number`,
  `function lastErrorText() as String` (e.g. `"-300 network timeout (phone) on /api/v1/watch/workout/live"`, `"nothing tried yet"` when `_lastCode == 0`),
  `function probeText() as String` (`"not tested"` / `"testing..."` / `"ok (200)"` / the describeCode text), `function isEndpointOk() as Boolean`.
- **Live sync must stop being silent**: `onLive` failure now sets the sync note
  (`"live sync failed - " + LiftEndpoint.describeCode(code)`, only when the text
  changes, so the screen is not repainted on every failure) in addition to the
  existing System.println, and keeps the durable stash behaviour exactly as it is.
  `postLiveSet()` must remain non-blocking and keep `_liveInFlight`/`_liveQueued`.
- `retryPending()` must now be callable after a successful discovery too: expose
  `function hasPending() as Boolean` and call `retryPending()` from `onStart()`
  when there is anything pending (existing call site), plus after a discovery
  result lands. Keep the existing semantics: the retry UPDATES the same record id
  when one is remembered, never duplicating.
- Every URL the app builds must contain no `//` after the scheme and no trailing
  slash before `?`.

## 3. `Workout.mc` — thin pass-throughs only
Add (delegating to `_comms`, null-guarded, no behaviour change otherwise):
`function diagLines() as Array<String>`, `function testEndpoint() as Void`,
`function endpointText() as String`, `function lastSyncText() as String`,
`function hasPendingWorkout() as Boolean`, `function probeText() as String`.
`diagLines()` returns, in order:
1. `"ENDPOINT (" + _comms.candidateCount() + " candidates)"`
2. the current base URL
3. `"last: " + _comms.lastErrorText()`
4. `"probe: " + _comms.probeText()`
5. `"pending: " + ("yes" if a stash exists else "no")`
6. `"garmin: " + activityNote()`
7. `"hold SELECT to test"`

## 4. `WorkoutUi.mc`
- New `SyncStatusView` (WatchUi.View) + `SyncStatusDelegate` (BehaviorDelegate),
  modelled on the existing `ExerciseInfoView`/`InfoDelegate` and `ListPickerView`
  patterns (same drawing helpers `drawCentered`, `LIFT_TEXT`, `LIFT_TEXT_DIM`,
  `LIFT_PURPLE_BRIGHT`, and the same paging idiom):
  - `onUpdate` draws the `_c.diagLines()` page selected by `_page`;
  - `onNextPage`/`onPreviousPage` move the page (clamped), `requestUpdate`;
  - `onSelect` (and `onMenu`) calls `_c.testEndpoint()`, then `WatchUi.requestUpdate()`;
  - `onBack` pops.
- Add a `"Sync status"` MenuItem (id `"status"`) to BOTH existing menus:
  the day-picker hold menu (`ListPickerDelegate.onMenu` → `PickerMenuDelegate`) and
  the workout options menu (`SetDelegate.onMenu` → `SetMenuDelegate`). Their
  delegates currently ignore the item id and always `System.exit()` / perform the
  action — branch on `item.getId()`: `"status"` pushes
  `new SyncStatusView(_c)` + `new SyncStatusDelegate(_c)` (SLIDE_UP), everything
  else keeps today's behaviour byte-for-byte.
- Do NOT reintroduce the removed live-workout/attach feature. Do NOT change heart
  rate handling. Never draw a fabricated value.

## 5. `endpoint_mirror.py` + tests
- `embedded/monkeyc/tools/endpoint_mirror.py`: a faithful Python translation of
  every `LiftEndpoint` function, in the same order, with a docstring stating the
  lockstep rule with `Endpoint.mc` (like `verify_watch_payload.py`'s
  `urlencode_mirror`). `--mc <path>` parses `Endpoint.mc` and asserts the mirror's
  constants match (the two DISCOVERY_URLS entries and HEALTH_PATH, plus
  `describeCode`'s string literals for -300/-1001/-104 as a spot check).
- `backend/python/tests/test_endpoint.py` (pytest; import the mirror by adding
  `../../embedded/monkeyc/tools` to `sys.path`): normalize (trailing slashes,
  spaces, tabs, uppercase `HTTPS://`, `http://` rejected, `http://127.0.0.1`
  accepted, empty/None, inner space); joinUrl (with/without trailing slash on the
  base, with/without leading slash on the path, empty base) and the exact
  trailing-slash regression `joinUrl("https://h/", "/api/v1/watch/programs")`
  contains no `//` after the scheme; candidates (order, dedupe, empties);
  shouldFollow/isRetryable across 200/204/301/307/308/400/404/422/500/503/-300/
  -104/-1001/0; nextIndex; describeCode exact strings; parseDiscovery with a valid
  dict, a missing key, a non-String value and a Null.

## Gates the orchestrator will re-run (do not run them yourself)
`cd backend/python && .venv/bin/python -m pytest tests/ -q` and
`cd embedded/monkeyc && tools/linux-build.sh venu2s` plus a mutation proof of the
follow logic. Never weaken or delete a test. Never `git checkout --`; back up any
file you mutate to `/tmp`. No secrets. Do not commit — the orchestrator commits.

## Report back
Files created/changed with `file:line` for each substantive change, the exact
commands you ran and their raw output, and anything you could not do or are
unsure about. Do not claim a gate passed if you did not run it.
