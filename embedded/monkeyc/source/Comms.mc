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

import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Cloudflare quick tunnel in front of the backend (see docs/06). A quick tunnel
// hostname changes when it restarts; this is now only the FALLBACK default -
// see backendUrl() below - because a rotated hostname used to require a full
// rebuild + re-sideload to fix (nothing on the watch could point at the new
// one). Swap this for a named tunnel on a real domain to make even the
// fallback permanent.
const LIFT_BACKEND = "https://transcripts-forward-acdbentity-ascii.trycloudflare.com";
// v1 key is deliberately abandoned: it held 422-era payloads (from the
// %00-encoder bug) that would otherwise be re-posted today with a 7.5-hour
// garbage duration. Bumping the key makes any old stashed value inert.
const PENDING_KEY = "lift_pending_workout_v2";

// Live-sync record handshake (Application.Storage; String values, "" == none).
// The literal key strings must match Workout.mc's clearSaved() exactly.
const LIVE_RECORD_KEY = "lift_live_record";       // this session's live record id
const PENDING_RECORD_KEY = "lift_pending_record"; // the id a stashed retry must UPDATE

class LiftComms {

    private var _controller;
    private var _planOk;
    private var _posted;
    private var _liveInFlight;   // one live-sync POST in flight at a time
    private var _liveQueued;     // another set completed while one was in flight
    private var _lastRecordId;   // the record id used for the last postWorkout() dispatch -
                                  // remembered because clearSaved() wipes LIVE_RECORD_KEY from
                                  // Storage synchronously, before the async response (and a
                                  // possible stashPending()) arrives.

    function initialize(c as WorkoutController) {
        _controller = c;
        _planOk = false;
        _posted = false;
        _liveInFlight = false;
        _liveQueued = false;
        _lastRecordId = "";
    }

    function planFetched() as Boolean { return _planOk; }
    function posted() as Boolean { return _posted; }

    // ------------------------------------------------------------- backend url

    // The endpoint is no longer baked into the binary alone: Application
    // Properties ("backendUrl", resources/properties.xml + settings.xml) can
    // be pushed from the phone (Garmin Express / Connect Mobile App Settings)
    // without a rebuild - the actual fix for a rotated quick-tunnel hostname
    // is now "push a new value", not "recompile and re-sideload". An
    // empty/unset property (fresh install, or a device predating this
    // setting) falls back to the compiled-in LIFT_BACKEND so the app still
    // works out of the box.
    private function backendUrl() as String {
        try {
            var v = Application.Properties.getValue("backendUrl");
            if (v instanceof String and !(v as String).equals("")) { return v as String; }
        } catch (e) {
            // No properties.xml entry on an old build, or a bad value type -
            // fall back rather than let a settings problem cost the workout.
        }
        return LIFT_BACKEND;
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

    // -------------------------------------------------------------------- plan

    // The user's programs, so they can pick one on the watch.
    function fetchPrograms() as Void {
        Communications.makeWebRequest(backendUrl() + "/api/v1/watch/programs", null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onProgramsResponse));
    }

    function onProgramsResponse(responseCode as Number,
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
        var url = backendUrl() + "/api/v1/watch/plan?program=" + urlEncode(programId);
        System.println("Comms: GET " + url);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onPlanResponse));
    }

    function onPlanResponse(responseCode as Number,
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
        var url = backendUrl() + "/api/v1/watch/exercise?name=" + urlEncode(name);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onExerciseInfo));
    }

    function onExerciseInfo(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        if (responseCode == 200 and (data instanceof Dictionary)) {
            _controller.setExerciseInfo(data as Dictionary);
        } else {
            _controller.setExerciseInfo(null);
        }
        WatchUi.requestUpdate();
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
        // the process outright - onPostResponse() then never runs, so a
        // stash written only from its failure branch would never happen and
        // the finished workout would be silently lost with no retry queued.
        // Stashing first and clearing only on a confirmed 2xx (below, and in
        // onPostResponse()) makes the outcome watchdog-timing-independent:
        // worst case a request that actually succeeded gets retried once
        // more, which is a harmless update (same record id, same-or-longer
        // set list, server-side never-shrink guard) rather than a loss.
        stashPending();
        // finished=1 is the ONLY way this backend can mark a record "done" -
        // it can't omit endTime at all (see backend/python/app/watch_api.py's
        // module docstring); this drops the LIVE_NOTE marker used to find it
        // via /watch/workout/active instead.
        var url = backendUrl() + "/api/v1/watch/workout/live?payload=" + urlEncode(payload) +
                  "&record=" + urlEncode(_lastRecordId) + "&finished=1";
        System.println("Comms: POST (query) " + url);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onPostResponse));
        return true;
    }

    function onPostResponse(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
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
        _controller.setSyncNote("sync failed " + responseCode + " - will retry");
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
    // the first set, updates it on every later one. Decision #3: silent -
    // never surfaces a failure and never blocks the workout UI.
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
        // this state is confirmed (onLiveResponse() below) or the finish POST
        // lands. This is what survives the tunnel being down for part of a
        // workout, or the app being killed - retryPending() (called from
        // onStart()) resends it at the next launch, updating the SAME record
        // id (or creating one if none was ever confirmed); never a duplicate,
        // since there is exactly one id remembered and the backend's
        // never-shrink guard makes a resend of already-applied state a no-op.
        _lastRecordId = rid;
        stashPending();
        var url = backendUrl() + "/api/v1/watch/workout/live?payload=" + urlEncode(payload) +
                  "&record=" + urlEncode(rid);
        _liveInFlight = true;
        System.println("Comms: POST live " + url);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onLiveResponse));
    }

    function onLiveResponse(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        _liveInFlight = false;
        if (responseCode >= 200 and responseCode < 300 and (data instanceof Dictionary)) {
            var id = (data as Dictionary)["id"];
            if (id != null) {
                Application.Storage.setValue(LIVE_RECORD_KEY, id.toString());
            }
            // Confirmed: this state has landed, so the durable retry copy
            // stashed before the request (postLiveSet() above) is no longer
            // needed. A set completed WHILE this request was in flight left
            // _liveQueued set - postLiveSet() below re-stashes the newer
            // state before sending it, so nothing is lost in that overlap.
            clearStashed();
            System.println("Comms: live sync ok (" + responseCode + ")");
        } else {
            // Still invisible to the UI by design (decision #3) - but no
            // longer silent to Storage: the payload this attempt carried is
            // already durably stashed (postLiveSet() above), so it is not
            // lost even if every later live-sync attempt also fails and the
            // app never gets a chance to retry before the workout ends.
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
        if (rid.equals("")) { return; }
        var url = backendUrl() + "/api/v1/watch/workout/discard?record=" + urlEncode(rid);
        System.println("Comms: POST discard " + url);
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onDiscardResponse));
    }

    function onDiscardResponse(responseCode as Number,
                               data as Dictionary or String or Null) as Void {
        System.println("Comms: discard result (" + responseCode + ")");
    }
}
