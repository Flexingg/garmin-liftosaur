// Liftosaur watch — backend client (fetch the plan, push the workout).
//
// The watch talks to OUR backend, never to Liftosaur: the API key stays server
// side. Two calls:
//
//   GET  /api/v1/watch/plan?section=...   refresh the plan at workout start
//   POST /api/v1/watch/workout            hand over the logged sets
//
// https is MANDATORY: the platform returns SECURE_CONNECTION_REQUIRED (-1001)
// for a plain http URL, which is why the backend is fronted by a tunnel with a
// real certificate instead of being called on the LAN.
//
// Failure policy:
//   - plan fetch fails  -> keep the plan baked into the app (PlanData.mc). The
//     workout must never be blocked by the network.
//   - workout post fails -> stash it and retry on the next launch. Losing a
//     finished session is the worst thing this app could do.
//
// Endpoint policy (Endpoint.mc has the pure rules):
//   - every URL is built by dispatch() from a normalised base URL and a path,
//     never by string concatenation at the call site;
//   - base URLs are tried in order: the last one that worked (Storage), the
//     backendUrl property, the compiled-in LIFT_BACKEND. A failure (anything
//     but a 2xx, incl. GCM's -300 "timed out") moves on to the next one; a 3xx
//     (which makeWebRequest never follows) is first retried once as-is;
//   - once every candidate has failed, the current quick-tunnel hostname is
//     looked up ONCE from a stable JSON document (LiftEndpoint.DISCOVERY_URLS)
//     and the original request is re-sent against it.

import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Cloudflare quick tunnel in front of the backend (see docs/06). A quick tunnel
// hostname changes when it restarts; this is now only the LAST candidate -
// see LiftComms.initialize() below - because a rotated hostname used to require
// a full rebuild + re-sideload to fix (nothing on the watch could point at the
// new one). Swap this for a named tunnel on a real domain to make even the
// fallback permanent.
const LIFT_BACKEND = "https://them-pda-classifieds-experts.trycloudflare.com";
// v1 key is deliberately abandoned: it held 422-era payloads (from the
// %00-encoder bug) that would otherwise be re-posted today with a 7.5-hour
// garbage duration. Bumping the key makes any old stashed value inert.
const PENDING_KEY = "lift_pending_workout_v2";

// Live-sync record handshake (Application.Storage; String values, "" == none).
// The literal key strings must match Workout.mc's clearSaved() exactly.
const LIVE_RECORD_KEY = "lift_live_record";       // this session's live record id
const PENDING_RECORD_KEY = "lift_pending_record"; // the id a stashed retry must UPDATE

// The last base URL that actually answered with a 2xx (or the one discovery
// found). Tried first on the next request and the next launch.
const BACKEND_KEY = "lift_backend_learned";

class LiftComms {

    private var _controller;
    private var _planOk;
    private var _posted;
    private var _liveInFlight;   // one live-sync POST in flight at a time
    private var _liveQueued;     // another set completed while one was in flight
    private var _currentInFlight;// fetchCurrentWorkout request in flight
    private var _exerciseInFlight;// fetchExerciseInfo request in flight
    private var _postInFlight;   // the finish POST is in flight
    private var _lastRecordId;   // the record id used for the last postWorkout() dispatch -
                                  // remembered because clearSaved() wipes LIVE_RECORD_KEY from
                                  // Storage synchronously, before the async response (and a
                                  // possible stashPending()) arrives.

    // Endpoint state.
    private var _cands;          // Array<String>: normalised base URLs, in try order
    private var _candIdx;        // index into _cands of the base in use
    private var _extras;         // kind -> extra of its in-flight request (for a re-send)
    private var _usedIdx;        // kind -> candidate index its in-flight request went to
    private var _followed;       // kind -> true once a 3xx has been retried as-is
    private var _tries;          // kind -> dispatches for the current operation (loop guard)
    private var _discoveryTried; // discovery already attempted since the last 2xx
    private var _discovering;    // a discovery request is in flight
    private var _discIdx;        // which DISCOVERY_URLS entry is in flight
    private var _discKind;       // the request to re-send once discovery lands
    private var _discExtra;
    private var _discCode;       // the failure that triggered discovery

    // Diagnostics (SyncStatusView).
    private var _lastCode;       // 0 = nothing answered yet
    private var _lastPathText;   // path (no query) of the request behind _lastCode
    private var _probeOk;
    private var _probeCode;
    private var _probeDone;
    private var _probeRunning;

    function initialize(c as WorkoutController) {
        _controller = c;
        _planOk = false;
        _posted = false;
        _liveInFlight = false;
        _liveQueued = false;
        _currentInFlight = false;
        _exerciseInFlight = false;
        _postInFlight = false;
        _lastRecordId = "";

        _cands = LiftEndpoint.candidates(learnedBackend(), configuredBackend(), LIFT_BACKEND);
        _candIdx = 0;
        _extras = {};
        _usedIdx = {};
        _followed = {};
        _tries = {};
        _discoveryTried = false;
        _discovering = false;
        _discIdx = 0;
        _discKind = "";
        _discExtra = null;
        _discCode = 0;

        _lastCode = 0;
        _lastPathText = "";
        _probeOk = false;
        _probeCode = 0;
        _probeDone = false;
        _probeRunning = false;
    }

    function planFetched() as Boolean { return _planOk; }
    function posted() as Boolean { return _posted; }

    // ------------------------------------------------------------- backend url

    // The endpoint is no longer baked into the binary alone: Application
    // Properties ("backendUrl", resources/properties.xml + settings.xml) can
    // be pushed from the phone (Garmin Express / Connect Mobile App Settings)
    // without a rebuild. An empty/unset property (fresh install, or a device
    // predating this setting) simply drops out of the candidate list.
    private function configuredBackend() as String or Null {
        try {
            var v = Application.Properties.getValue("backendUrl");
            if (v instanceof String) { return v as String; }
        } catch (e) {
            // No properties.xml entry on an old build, or a bad value type -
            // skip it rather than let a settings problem cost the workout.
        }
        return null;
    }

    private function learnedBackend() as String or Null {
        var v = Application.Storage.getValue(BACKEND_KEY);
        if (v instanceof String) { return v as String; }
        return null;
    }

    // The base URL requests currently go to.
    function baseUrl() as String {
        if (_cands.size() == 0) { return LIFT_BACKEND; }
        if (_candIdx < 0 or _candIdx >= _cands.size()) { _candIdx = 0; }
        return _cands[_candIdx] as String;
    }

    private function baseAt(idx as Number) as String {
        if (idx < 0 or idx >= _cands.size()) { return baseUrl(); }
        return _cands[idx] as String;
    }

    // ---------------------------------------------------------------- encoding

    // Percent-encode a string for use in a URL query (RFC 3986).
    //
    // Characters MUST come from toCharArray(): on a 1-character STRING,
    // toNumber() parses a number ("5".toNumber() == 5) and returns null for
    // anything else - so "/".toNumber() was null, fell back to 0, and this
    // function emitted "%00" (NUL) for every reserved character. The whole
    // workout payload then lost its "|" and ";" separators in flight and the
    // backend rejected it with 422. Char.toNumber() gives the code point.
    function urlEncode(s as String) as String {
        var hex = "0123456789ABCDEF";
        var out = "";
        var chars = s.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var v = (chars[i] as Char).toNumber();
            var unreserved = (v >= 0x41 and v <= 0x5A) or    // A-Z
                             (v >= 0x61 and v <= 0x7A) or    // a-z
                             (v >= 0x30 and v <= 0x39) or    // 0-9
                             v == 0x2D or v == 0x5F or       // - _
                             v == 0x2E or v == 0x7E;         // . ~
            if (v < 0 or v > 0xFF) {
                // Not a byte (the plan and exercise names are ASCII); never emit
                // a stray "%" that would truncate the query.
                out += "_";
            } else if (unreserved) {
                out += s.substring(i, i + 1);
            } else {
                var hi = (v / 16) % 16;
                var lo = v % 16;
                out += "%" + hex.substring(hi, hi + 1) + hex.substring(lo, lo + 1);
            }
        }
        return out;
    }

    // ---------------------------------------------------------------- dispatch

    // The path (and query) for each kind of request. "post" is the finish
    // POST: the same live endpoint, with extra["finished"] set.
    private function pathFor(kind as String, extra as Dictionary or Null) as String {
        var x = (extra == null) ? {} : extra as Dictionary;
        if (kind.equals("programs")) { return "/api/v1/watch/programs"; }
        if (kind.equals("plan")) {
            return "/api/v1/watch/plan?program=" + urlEncode(x["program"] as String);
        }
        if (kind.equals("exercise")) {
            return "/api/v1/watch/exercise?name=" + urlEncode(x["name"] as String);
        }
        if (kind.equals("current")) { return "/api/v1/watch/workout/current"; }
        if (kind.equals("live") or kind.equals("post")) {
            var p = "/api/v1/watch/workout/live?payload=" + urlEncode(x["payload"] as String) +
                    "&record=" + urlEncode(x["record"] as String);
            // finished=1 rides on the "post" kind only (postWorkout schedules it;
            // postLiveSet never does). Keyed off the kind, not off a dictionary
            // lookup: the compiler warns "statement is not reachable" for the
            // dynamic form, and this is the one flag whose loss would silently
            // leave every finished workout marked "in progress" in Liftosaur.
            if (kind.equals("post")) { p += "&finished=1"; }
            return p;
        }
        if (kind.equals("discard")) {
            return "/api/v1/watch/workout/discard?record=" + urlEncode(x["record"] as String);
        }
        return LiftEndpoint.HEALTH_PATH;   // "health"
    }

    // The path without its query, for the status screen.
    private function pathText(kind as String, extra as Dictionary or Null) as String {
        var p = pathFor(kind, extra);
        var q = p.find("?");
        return (q == null) ? p : p.substring(0, q) as String;
    }

    // The backend's routes: the live/discard writes are POST-only (a GET
    // there is a 405), everything else is GET.
    private function isPost(kind as String) as Boolean {
        return kind.equals("live") or kind.equals("post") or kind.equals("discard");
    }

    // Start a new operation: resets the per-operation retry bookkeeping.
    private function request(kind as String, extra as Dictionary or Null) as Void {
        _tries.put(kind, 0);
        _followed.remove(kind);
        dispatch(kind, extra);
    }

    // The ONE place a backend request is made.
    private function dispatch(kind as String, extra as Dictionary or Null) as Void {
        _extras.put(kind, (extra == null) ? {} : extra);
        _usedIdx.put(kind, _candIdx);
        var n = _tries[kind];
        _tries.put(kind, ((n == null) ? 0 : n as Number) + 1);
        var url = LiftEndpoint.joinUrl(baseUrl(), pathFor(kind, extra));
        var post = isPost(kind);
        System.println("Comms: " + (post ? "POST " : "GET ") + url);
        // makeWebRequest's callback cannot carry the kind, and several
        // requests are in flight at once at launch (programs, current, a
        // retry), so a single "pending kind" field would route one request's
        // answer to another's handler. Each kind gets a one-line trampoline
        // into the same handleResponse().
        var cb = method(:onHealthResponse);
        if (kind.equals("programs")) { cb = method(:onProgramsResponse); }
        else if (kind.equals("plan")) { cb = method(:onPlanResponse); }
        else if (kind.equals("exercise")) { cb = method(:onExerciseResponse); }
        else if (kind.equals("current")) { cb = method(:onCurrentResponse); }
        else if (kind.equals("live")) { cb = method(:onLiveResponse); }
        else if (kind.equals("post")) { cb = method(:onPostResponse); }
        else if (kind.equals("discard")) { cb = method(:onDiscardResponse); }
        Communications.makeWebRequest(url, null, {
            :method => post ? Communications.HTTP_REQUEST_METHOD_POST
                            : Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, cb);
    }

    function onProgramsResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("programs", code, data); }
    function onPlanResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("plan", code, data); }
    function onExerciseResponse(code as Number, data as Dictionary or String or Null) as Void {
        _exerciseInFlight = false;
        handleResponse("exercise", code, data);
    }
    function onCurrentResponse(code as Number, data as Dictionary or String or Null) as Void {
        _currentInFlight = false;
        handleResponse("current", code, data);
    }
    function onLiveResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("live", code, data); }
    function onPostResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("post", code, data); }
    function onDiscardResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("discard", code, data); }
    function onHealthResponse(code as Number, data as Dictionary or String or Null) as Void { handleResponse("health", code, data); }

    private function handleResponse(kind as String, code as Number,
                                    data as Dictionary or String or Null) as Void {
        var extra = _extras[kind] as Dictionary or Null;
        if (!LiftEndpoint.isRetryable(code)) {
            noteSuccess(kind, extra, code);
        } else if (failover(kind, extra, code)) {
            return;   // re-sent (another base, or after discovery): wait for that answer
        }
        route(kind, code, data);
    }

    // Hand a final answer to the per-kind logic.
    private function route(kind as String, code as Number,
                           data as Dictionary or String or Null) as Void {
        if (kind.equals("programs")) { onPrograms(code, data); }
        else if (kind.equals("plan")) { onPlan(code, data); }
        else if (kind.equals("exercise")) { onExerciseInfo(code, data); }
        else if (kind.equals("current")) { onCurrentWorkout(code, data); }
        else if (kind.equals("live")) { onLive(code, data); }
        else if (kind.equals("post")) { onPost(code, data); }
        else if (kind.equals("discard")) { onDiscard(code, data); }
        else { onHealth(code, data); }
    }

    private function noteSuccess(kind as String, extra as Dictionary or Null, code as Number) as Void {
        _lastCode = code;
        _lastPathText = pathText(kind, extra);
        var used = _usedIdx[kind];
        Application.Storage.setValue(BACKEND_KEY, baseAt((used == null) ? _candIdx : used as Number));
        _discoveryTried = false;
        _followed.remove(kind);
    }

    // A non-2xx answer: re-send somewhere that might work. Returns true when a
    // request was re-sent (the caller then waits for THAT answer), false when
    // the failure is final and must go to the per-kind handler.
    private function failover(kind as String, extra as Dictionary or Null, code as Number) as Boolean {
        _lastCode = code;
        _lastPathText = pathText(kind, extra);
        if (!LiftEndpoint.isRetryable(code)) { return false; }
        var tries = _tries[kind];
        if (tries != null and (tries as Number) > (_cands.size() * 2) + 2) {
            return surface(kind, code);   // loop guard: never retry forever
        }
        var usedRaw = _usedIdx[kind];
        var used = (usedRaw == null) ? _candIdx : usedRaw as Number;
        // A redirect is never followed by makeWebRequest: retry the same base
        // once with the canonical URL dispatch() builds.
        if (LiftEndpoint.shouldFollow(code) and _followed[kind] != true) {
            _followed.put(kind, true);
            System.println("Comms: " + kind + " got " + code + ", retrying canonical URL");
            dispatch(kind, extra);
            return true;
        }
        _followed.remove(kind);
        if (_candIdx != used) {
            // Another request already moved on to a different base while
            // this one was in flight: try that one rather than skipping it.
            dispatch(kind, extra);
            return true;
        }
        var next = LiftEndpoint.nextIndex(used, _cands.size());
        if (next != -1) {
            System.println("Comms: " + kind + " failed (" + code + ") on " + baseUrl() +
                           ", trying " + (_cands[next] as String));
            _candIdx = next;
            dispatch(kind, extra);
            return true;
        }
        if (!_discoveryTried and !_discovering) {
            _discoveryTried = true;
            _discCode = code;
            discover(kind, extra, 0);
            return true;
        }
        return surface(kind, code);
    }

    // Every base failed: the next operation starts from the preferred base
    // again (the tunnel may come back), and the caller reports the failure.
    private function surface(kind as String, code as Number) as Boolean {
        _candIdx = 0;
        System.println("Comms: " + kind + " failed on every endpoint: " + lastErrorText());
        return false;
    }

    // ---------------------------------------------------------------- discovery

    // Look up the current tunnel hostname. Only reached after every candidate
    // failed, at most once until something succeeds again; asynchronous, so
    // the UI is never blocked.
    private function discover(kind as String, extra as Dictionary or Null, idx as Number) as Void {
        _discovering = true;
        _discKind = kind;
        _discExtra = extra;
        _discIdx = idx;
        var url = LiftEndpoint.DISCOVERY_URLS[idx] as String;
        System.println("Comms: discovering backend via " + url);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onDiscoveryResponse));
    }

    function onDiscoveryResponse(code as Number, data as Dictionary or String or Null) as Void {
        var found = "";
        if (!LiftEndpoint.isRetryable(code)) {
            found = LiftEndpoint.parseDiscovery(data);
        }
        var kind = _discKind as String;
        var extra = _discExtra as Dictionary or Null;
        if (found.equals("")) {
            var next = _discIdx + 1;
            if (next < LiftEndpoint.DISCOVERY_URLS.size()) {
                discover(kind, extra, next);
                return;
            }
            _discovering = false;
            System.println("Comms: discovery found nothing (" + code + ")");
            // Report the ORIGINAL failure to the request that was waiting.
            _lastCode = _discCode;
            _lastPathText = pathText(kind, extra);
            surface(kind, _discCode);
            route(kind, _discCode, null);
            return;
        }
        // Front of the list, without duplicating an entry already there.
        var list = [found] as Array<String>;
        for (var i = 0; i < _cands.size(); i++) {
            if (!(_cands[i] as String).equals(found)) { list.add(_cands[i] as String); }
        }
        _cands = list;
        _candIdx = 0;
        _discoveryTried = true;
        _discovering = false;
        Application.Storage.setValue(BACKEND_KEY, found);
        System.println("Comms: discovered backend " + found);
        _tries.put(kind, 0);
        dispatch(kind, extra);
        // A stashed workout can go now too - but never mid-workout (the retry
        // reloads the stash into the controller and posts it as finished) and
        // never when the re-sent request already carries it.
        if (hasPending() and !_controller.isStarted() and !_postInFlight and
            !kind.equals("live") and !kind.equals("post")) {
            retryPending();
        }
    }

    // ------------------------------------------------------------ diagnostics

    // Test the endpoint from the status screen. Goes through the same
    // failover/discovery as every other request; never touches the sync note.
    function probeEndpoint() as Void {
        _probeRunning = true;
        _probeDone = false;
        request("health", null);
        WatchUi.requestUpdate();
    }

    private function onHealth(code as Number, data as Dictionary or String or Null) as Void {
        _probeRunning = false;
        _probeDone = true;
        _probeCode = code;
        _probeOk = !LiftEndpoint.isRetryable(code);
        System.println("Comms: health " + code);
        WatchUi.requestUpdate();
    }

    function endpointText() as String { return baseUrl(); }
    function candidateCount() as Number { return _cands.size(); }
    function lastCode() as Number { return _lastCode; }

    function lastErrorText() as String {
        if (_lastCode == 0) { return "nothing tried yet"; }
        return _lastCode + " " + LiftEndpoint.describeCode(_lastCode) + " on " + _lastPathText;
    }

    function probeText() as String {
        if (_probeRunning) { return "testing..."; }
        if (!_probeDone) { return "not tested"; }
        if (_probeOk) { return "ok (" + _probeCode + ")"; }
        return LiftEndpoint.describeCode(_probeCode);
    }

    function isEndpointOk() as Boolean {
        if (_probeDone) { return _probeOk; }
        return !LiftEndpoint.isRetryable(_lastCode);
    }

    // -------------------------------------------------------------------- plan

    // The user's programs, so they can pick one on the watch.
    function fetchPrograms() as Void {
        request("programs", null);
    }

    private function onPrograms(responseCode as Number,
                                data as Dictionary or String or Null) as Void {
        if (responseCode == 200 and (data instanceof Dictionary)) {
            var progs = (data as Dictionary)["programs"];
            if (progs instanceof Array and (progs as Array).size() > 0) {
                _controller.setPrograms(progs as Array);
                System.println("Comms: " + (progs as Array).size() + " programs");
            }
        }
        // Whatever happened, the plan still needs fetching for the chosen program.
        fetchPlan(_controller.chosenProgramId());
    }

    // NOTE: deliberately no ?section filter any more - the user wants the WHOLE
    // program (all week-blocks, deload included) on the watch.
    function fetchPlan(programId as String) as Void {
        request("plan", {"program" => programId});
    }

    private function onPlan(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            // Keep the baked-in plan. Not an error worth bothering the user with.
            System.println("Comms: plan fetch failed (" + responseCode + "), using built-in plan");
            return;
        }
        var raw = data as Dictionary;
        var prog = raw["program"];
        if (prog instanceof String) {
            _controller.setProgram(prog as String);
        }
        var days = normalizePlan(raw);
        if (days.size() == 0) {
            System.println("Comms: plan had no days, using built-in plan");
            return;
        }
        _controller.adoptRemotePlan(days);
        _planOk = true;
        System.println("Comms: adopted remote plan (" + days.size() + " days)");
        fetchCurrentWorkout();
    }

    // JSON gives string keys; the baked-in plan uses symbols. Normalise so the
    // controller has exactly one shape to deal with.
    private function normalizePlan(raw as Dictionary) as Array {
        var out = [];
        var days = raw["days"];
        if (!(days instanceof Array)) { return out; }
        for (var i = 0; i < (days as Array).size(); i++) {
            var d = (days as Array)[i];
            if (!(d instanceof Dictionary)) { continue; }
            var dd = d as Dictionary;
            var exs = [];
            var rawExs = dd["exercises"];
            if (rawExs instanceof Array) {
                for (var j = 0; j < (rawExs as Array).size(); j++) {
                    var e = (rawExs as Array)[j];
                    if (!(e instanceof Dictionary)) { continue; }
                    var ee = e as Dictionary;
                    var sets = [];
                    var rawSets = ee["sets"];
                    if (rawSets instanceof Array) {
                        for (var k = 0; k < (rawSets as Array).size(); k++) {
                            var s = (rawSets as Array)[k];
                            if (!(s instanceof Dictionary)) { continue; }
                            var ss = s as Dictionary;
                            sets.add({
                                :reps => ss["reps"], :weight => ss["weight"],
                                :amrap => ss["amrap"], :rest => ss["rest"]
                            });
                        }
                    }
                    exs.add({:name => ee["name"], :rest => ee["rest"], :sets => sets});
                }
            }
            out.add({:name => dd["name"], :section => dd["section"], :exercises => exs});
        }
        return out;
    }

    // Previous session for one exercise, for the info screen.
    function fetchExerciseInfo(name as String) as Void {
        if (_exerciseInFlight) { return; }
        _exerciseInFlight = true;
        request("exercise", {"name" => name});
    }

    private function onExerciseInfo(responseCode as Number,
                                    data as Dictionary or String or Null) as Void {
        _exerciseInFlight = false;
        if (responseCode == 200 and (data instanceof Dictionary)) {
            _controller.setExerciseInfo(data as Dictionary);
        } else {
            _controller.setExerciseInfo(null);
        }
        WatchUi.requestUpdate();
    }

    // Active workout sync: check if phone or outside client has an ongoing workout.
    function fetchCurrentWorkout() as Void {
        if (_currentInFlight or _liveInFlight or _postInFlight) { return; }
        _currentInFlight = true;
        request("current", null);
    }

    private function onCurrentWorkout(responseCode as Number,
                                      data as Dictionary or String or Null) as Void {
        if (responseCode == 200 and (data instanceof Dictionary)) {
            var active = (data as Dictionary)["active"];
            if (active instanceof Boolean and (active as Boolean)) {
                var w = (data as Dictionary)["workout"];
                if (w instanceof Dictionary) {
                    _controller.adoptLiveWorkout(w as Dictionary);
                    System.println("Comms: adopted live workout from phone");
                }
            }
        }
    }

    // ----------------------------------------------------------------- workout

    // The record id to send with the finish/retry POST: this session's live
    // record if one exists, else the id a stashed retry must update, else "".
    private function _recordForSave() as String {
        var live = Application.Storage.getValue(LIVE_RECORD_KEY);
        if (live != null) { return live as String; }
        var pending = Application.Storage.getValue(PENDING_RECORD_KEY);
        if (pending != null) { return pending as String; }
        return "";
    }

    // Returns true when a request was actually dispatched (so the caller knows
    // whether there is anything worth waiting for before the app exits).
    //
    // Posts to the LIVE endpoint (not /watch/workout): it already implements
    // exactly what finish needs - create when no record id is held, update
    // otherwise - so a Save updates the live record instead of duplicating it,
    // and "no live record yet" behaves exactly like a plain create (today's
    // behaviour, unchanged).
    function postWorkout() as Boolean {
        // The POST body path crashed twice: makeWebRequest serialises
        // `parameters` into the body and rejected both a nested dictionary and a
        // flat symbol-keyed one with "Unexpected Type Error". So there is NO
        // body: the workout rides in the query string and parameters stays null.
        var payload = _controller.outgoingPayload();
        if (payload == null or payload.equals("")) {
            System.println("Comms: nothing to post");
            return false;
        }
        _lastRecordId = _recordForSave();
        // Stash BEFORE dispatching, not just on a confirmed failure: the
        // 8s exit watchdog (Workout.mc requestExit()/finishExit()) can call
        // System.exit() while this request is still in flight, which kills
        // the process outright - onPost() then never runs, so a stash written
        // only from its failure branch would never happen and the finished
        // workout would be silently lost with no retry queued. Stashing first
        // and clearing only on a confirmed 2xx (below, and in onPost()) makes
        // the outcome watchdog-timing-independent: worst case a request that
        // actually succeeded gets retried once more, which is a harmless
        // update (same record id, same-or-longer set list, server-side
        // never-shrink guard) rather than a loss.
        stashPending();
        // finished=1 is the ONLY way this backend can mark a record "done" -
        // it can't omit endTime at all (see backend/python/app/watch_api.py's
        // module docstring); this drops the LIVE_NOTE marker used to find it
        // via /watch/workout/active instead.
        _postInFlight = true;
        request("post", {"payload" => payload, "record" => _lastRecordId});
        return true;
    }

    private function onPost(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        _postInFlight = false;
        if (responseCode >= 200 and responseCode < 300) {
            _posted = true;
            _controller.clearPending();
            clearStashed();
            Application.Storage.deleteValue(LIVE_RECORD_KEY);
            _controller.setSyncNote("synced to Liftosaur");
            System.println("Comms: workout recorded (" + responseCode + ")");
            WatchUi.requestUpdate();
            // Only closes the app when an exit is actually pending (Task 1) - a
            // background retry fired from app start must not do this.
            _controller.finishExit();
            return;
        }
        // Name the failure the way the user can act on it: the raw code is kept
        // alongside a plain-language reason, because -300 (Garmin Connect
        // Mobile's "network request timed out", NOT an HTTP status) is what a
        // rotated tunnel hostname looks like from the wrist.
        _controller.setSyncNote("sync failed " + responseCode + " " +
                                LiftEndpoint.describeCode(responseCode) + " - will retry");
        WatchUi.requestUpdate();
        // Keep it: retried on the next launch.
        System.println("Comms: workout post FAILED (" + responseCode + "), stashing");
        stashPending();
        _controller.finishExit();
    }

    // ------------------------------------------------------- pending (retry)

    // The body is already flat, so it stashes as a compact string: no JSON
    // encoder is available on this runtime and Storage cannot hold a dict.
    function stashPending() as Void {
        var text = _controller.pendingText();
        if (text == null or text.equals("")) { return; }
        Application.Storage.setValue(PENDING_KEY, text);
        // So the retry UPDATES this same record instead of creating a second
        // one. Read from _lastRecordId (not Storage): resolveSave() already
        // ran clearSaved() by the time this failure callback fires, which has
        // already wiped LIVE_RECORD_KEY.
        if (_lastRecordId != null and !_lastRecordId.equals("")) {
            Application.Storage.setValue(PENDING_RECORD_KEY, _lastRecordId);
        }
    }

    // Drop the durable retry state once a request has actually been
    // confirmed to land (a 2xx for the finish POST or a live-sync set).
    private function clearStashed() as Void {
        Application.Storage.deleteValue(PENDING_KEY);
        Application.Storage.deleteValue(PENDING_RECORD_KEY);
    }

    // A workout (finished or live-so-far) is stashed, waiting for a retry.
    function hasPending() as Boolean {
        return Application.Storage.getValue(PENDING_KEY) != null;
    }

    function retryPending() as Void {
        var text = Application.Storage.getValue(PENDING_KEY);
        if (text == null) { return; }
        if (!_controller.loadPendingText(text as String)) {
            Application.Storage.deleteValue(PENDING_KEY);
            return;
        }
        System.println("Comms: retrying a stashed workout");
        postWorkout();
    }

    // -------------------------------------------------------------- live sync

    // Push the workout-so-far after each completed set: creates the record on
    // the first set, updates it on every later one. Never blocks the workout
    // UI; a final failure shows up only as the sync note.
    function postLiveSet() as Void {
        // One request in flight at a time: a shorter payload landing after a
        // longer one would overwrite the record with fewer sets. Queue instead
        // and re-read the CURRENT (by-then-longer) payload once the in-flight
        // request resolves.
        if (_liveInFlight) {
            _liveQueued = true;
            return;
        }
        var payload = _controller.livePayload();
        if (payload == null or payload.equals("")) { return; }
        var rid = _recordForSave();
        // Durable "latest known state": overwritten on every set (not just on
        // a confirmed failure) and cleared only once a live-sync response for
        // this state is confirmed (onLive() below) or the finish POST lands.
        // This is what survives the tunnel being down for part of a workout,
        // or the app being killed - retryPending() (called from onStart())
        // resends it at the next launch, updating the SAME record id (or
        // creating one if none was ever confirmed); never a duplicate, since
        // there is exactly one id remembered and the backend's never-shrink
        // guard makes a resend of already-applied state a no-op.
        _lastRecordId = rid;
        stashPending();
        _liveInFlight = true;
        request("live", {"payload" => payload, "record" => rid});
    }

    private function onLive(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        _liveInFlight = false;
        if (responseCode >= 200 and responseCode < 300 and (data instanceof Dictionary)) {
            var id = (data as Dictionary)["id"];
            if (id != null and !id.toString().equals("")) {
                Application.Storage.setValue(LIVE_RECORD_KEY, id.toString());
            }
            // Confirmed: this state has landed, so the durable retry copy
            // stashed before the request (postLiveSet() above) is no longer
            // needed. A set completed WHILE this request was in flight left
            // _liveQueued set - postLiveSet() below re-stashes the newer
            // state before sending it, so nothing is lost in that overlap.
            clearStashed();
            // A live-sync failure note is stale once a set lands again.
            var note = _controller.syncNote();
            if (note.length() >= 16 and (note.substring(0, 16) as String).equals("live sync failed")) {
                _controller.setSyncNote("");
                WatchUi.requestUpdate();
            }
            System.println("Comms: live sync ok (" + responseCode + ")");
        } else {
            // No longer silent: the reason is shown as the sync note (only
            // when it changes, so a run of failures does not repaint on every
            // set). The payload this attempt carried is already durably
            // stashed (postLiveSet() above), so it is not lost even if every
            // later live-sync attempt also fails and the app never gets a
            // chance to retry before the workout ends.
            var failNote = "live sync failed - " + LiftEndpoint.describeCode(responseCode);
            if (!failNote.equals(_controller.syncNote())) {
                _controller.setSyncNote(failNote);
                WatchUi.requestUpdate();
            }
            System.println("Comms: live sync failed (" + responseCode + ")");
        }
        if (_liveQueued) {
            _liveQueued = false;
            postLiveSet();
        }
    }

    // Discard deletes the live record - nothing left behind in Liftosaur
    // (decision #2). Fire-and-forget: the id is cleared locally right away,
    // whatever the network result turns out to be.
    function discardLive() as Void {
        var recordId = Application.Storage.getValue(LIVE_RECORD_KEY);
        var rid = (recordId != null) ? (recordId as String) : "";
        Application.Storage.deleteValue(LIVE_RECORD_KEY);
        request("discard", {"record" => rid});
    }

    private function onDiscard(responseCode as Number,
                               data as Dictionary or String or Null) as Void {
        System.println("Comms: discard result (" + responseCode + ")");
    }
}
