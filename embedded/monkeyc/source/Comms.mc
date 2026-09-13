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

// Cloudflare quick tunnel in front of the backend (see docs/06). A quick tunnel
// hostname changes when it restarts; swap this for a named tunnel on a real
// domain to make it permanent.
const LIFT_BACKEND = "https://transcripts-forward-acdbentity-ascii.trycloudflare.com";
const PENDING_KEY = "lift_pending_workout";

class LiftComms {

    private var _controller;
    private var _planOk;
    private var _posted;

    function initialize(c as WorkoutController) {
        _controller = c;
        _planOk = false;
        _posted = false;
    }

    function planFetched() as Boolean { return _planOk; }
    function posted() as Boolean { return _posted; }

    // ---------------------------------------------------------------- encoding

    // Minimal percent-encoding. String.replace() is not dependable across
    // runtimes and the only character we actually see is the space in "Week 1".
    function urlEncode(s as String) as String {
        var out = "";
        for (var i = 0; i < s.length(); i++) {
            var ch = s.substring(i, i + 1);
            if (ch.equals(" ")) {
                out += "%20";
            } else if (ch.equals("/") or ch.equals("?") or ch.equals("&") or ch.equals("#")) {
                // Not expected in a section name; substitute so the URL stays
                // well-formed rather than emitting a stray percent escape.
                out += "_";
            } else {
                out += ch;
            }
        }
        return out;
    }

    // -------------------------------------------------------------------- plan

    function fetchPlan(section as String) as Void {
        var url = LIFT_BACKEND + "/api/v1/watch/plan?section=" + urlEncode(section);
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

    // ----------------------------------------------------------------- workout

    function postWorkout() as Void {
        var body = _controller.buildWorkoutBodyOrPending();
        if (body == null) {
            System.println("Comms: nothing to post");
            return;
        }
        System.println("Comms: POST " + LIFT_BACKEND + "/api/v1/watch/workout");
        Communications.makeWebRequest(LIFT_BACKEND + "/api/v1/watch/workout", body, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {"Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON},
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onPostResponse));
    }

    function onPostResponse(responseCode as Number,
                            data as Dictionary or String or Null) as Void {
        if (responseCode >= 200 and responseCode < 300) {
            _posted = true;
            Application.Storage.deleteValue(PENDING_KEY);
            System.println("Comms: workout recorded (" + responseCode + ")");
            return;
        }
        // Keep it: retried on the next launch.
        System.println("Comms: workout post FAILED (" + responseCode + "), stashing");
        stashPending();
    }

    // ------------------------------------------------------- pending (retry)

    // The body is already flat, so it stashes as a compact string: no JSON
    // encoder is available on this runtime and Storage cannot hold a dict.
    function stashPending() as Void {
        var text = _controller.pendingText();
        if (text == null or text.equals("")) { return; }
        Application.Storage.setValue(PENDING_KEY, text);
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
}
