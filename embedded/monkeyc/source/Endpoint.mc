// Liftosaur watch — backend endpoint rules (pure: Lang only, no I/O).
//
// Every URL the app builds goes through this module, so the rules live in one
// place and can be mirrored (and tested) off-device:
//   tools/endpoint_mirror.py is a line-by-line Python translation of this
//   file, exercised by backend/python/tests/test_endpoint.py. Keep the two in
//   LOCKSTEP by hand - if one changes, change the other in the same commit.
//
// Why it exists: the base URL used to be concatenated verbatim, so a trailing
// "/" or a stray space in the backendUrl property produced "//api/v1/..." (404)
// or a 307 from FastAPI's trailing-slash redirect, which makeWebRequest does
// not follow. And the cloudflared quick-tunnel hostname rotates on every
// restart, so the app also needs a stable place to learn the current one.
//
// Monkey C's String has no trim()/replace()/startsWith(): the helpers below
// work on code points from toCharArray() and on substring().

import Toybox.Lang;

module LiftEndpoint {

    // Stable JSON documents ({"backend": "https://<host>.trycloudflare.com"})
    // naming the CURRENT tunnel hostname. Tried in order, and only after every
    // known base URL has failed.
    const DISCOVERY_URLS = [
        "https://raw.githubusercontent.com/Flexingg/garmin-liftosaur/main/endpoint.json",
        "https://cdn.jsdelivr.net/gh/Flexingg/garmin-liftosaur@main/endpoint.json"
    ];

    const HEALTH_PATH = "/api/v1/watch/health";

    // Space (0x20), tab (0x09) or "/" (0x2F).
    function isEdgeChar(v as Number) as Boolean {
        return v == 0x20 or v == 0x09 or v == 0x2F;
    }

    // Drop leading/trailing spaces, tabs and "/".
    function stripEdges(s as String) as String {
        var chars = s.toCharArray();
        var start = 0;
        var end = chars.size();
        while (start < end and isEdgeChar((chars[start] as Char).toNumber())) {
            start += 1;
        }
        while (end > start and isEdgeChar((chars[end - 1] as Char).toNumber())) {
            end -= 1;
        }
        return s.substring(start, end) as String;
    }

    // True when s begins with prefix, compared case-insensitively.
    function hasPrefixNoCase(s as String, prefix as String) as Boolean {
        if (s.length() < prefix.length()) { return false; }
        return (s.substring(0, prefix.length()) as String).toLower().equals(prefix.toLower());
    }

    // A usable base URL, or "" when there is none. https only: the platform
    // answers plain http with -1001 SECURE_CONNECTION_REQUIRED, except for the
    // loopback hosts the simulator allows. The https scheme is canonicalised
    // to lower case; the rest (host, any base path) is left exactly as given.
    function normalizeBaseUrl(raw as String or Null) as String {
        if (raw == null) { return ""; }
        var s = stripEdges(raw as String);
        if (s.equals("")) { return ""; }
        var rest = "";
        if (hasPrefixNoCase(s, "https://")) {
            rest = s.substring(8, s.length()) as String;
            s = "https://" + rest;
        } else if (hasPrefixNoCase(s, "http://")) {
            rest = s.substring(7, s.length()) as String;
            if (!hasPrefixNoCase(rest, "127.0.0.1") and !hasPrefixNoCase(rest, "localhost")) {
                return "";
            }
        } else {
            return "";
        }
        if (rest.find(" ") != null) { return ""; }
        return s;
    }

    // base + "/" + path with exactly one "/" between them; "" without a base.
    function joinUrl(base as String, path as String) as String {
        if (base.equals("")) { return ""; }
        var b = base;
        while (b.length() > 0 and (b.substring(b.length() - 1, b.length()) as String).equals("/")) {
            b = b.substring(0, b.length() - 1) as String;
        }
        var p = path;
        while (p.length() > 0 and (p.substring(0, 1) as String).equals("/")) {
            p = p.substring(1, p.length()) as String;
        }
        if (p.equals("")) { return b; }
        return b + "/" + p;
    }

    // The base URLs to try, in order: the last one that worked (learned), the
    // backendUrl property (configured), the compiled-in LIFT_BACKEND (baked).
    // Normalised, empties dropped, duplicates removed.
    function candidates(learned as String or Null, configured as String or Null,
                        baked as String or Null) as Array<String> {
        var out = [] as Array<String>;
        var raw = [learned, configured, baked];
        for (var i = 0; i < raw.size(); i++) {
            var n = normalizeBaseUrl(raw[i] as String or Null);
            if (n.equals("")) { continue; }
            var seen = false;
            for (var j = 0; j < out.size(); j++) {
                if ((out[j] as String).equals(n)) { seen = true; break; }
            }
            if (!seen) { out.add(n); }
        }
        return out;
    }

    // A redirect makeWebRequest refuses to follow.
    function shouldFollow(code as Number) as Boolean {
        return code >= 300 and code <= 399;
    }

    // Anything that is not a 2xx: 3xx/4xx/5xx and the negative CIQ/GCM
    // transport codes (-300 is Garmin Connect Mobile's "timed out").
    function isRetryable(code as Number) as Boolean {
        return !(code >= 200 and code <= 299);
    }

    // The next candidate index, or -1 when the candidates are exhausted.
    function nextIndex(current as Number, count as Number) as Number {
        if (current + 1 < count) { return current + 1; }
        return -1;
    }

    // Human text for a response code, short enough for the watch.
    function describeCode(code as Number) as String {
        if (code >= 200 and code <= 299) { return "ok"; }
        if (code >= 300 and code <= 399) { return code + " redirect"; }
        if (code >= 400 and code <= 499) { return code + " rejected"; }
        if (code >= 500 and code <= 599) { return code + " server error"; }
        if (code == -300) { return "network timeout (phone)"; }
        if (code == -1001) { return "https required"; }
        if (code == -104) { return "phone offline"; }
        if (code == -101) { return "no connection"; }
        if (code == -2) { return "network error"; }
        if (code < 0) { return "network error " + code; }
        if (code == 0) { return "not tried"; }
        return code.toString();
    }

    // The base URL named by a discovery document, or "" when it names none.
    function parseDiscovery(data as Dictionary or String or Null) as String {
        if (!(data instanceof Dictionary)) { return ""; }
        var v = (data as Dictionary)["backend"];
        if (!(v instanceof String)) { return ""; }
        return normalizeBaseUrl(v as String);
    }
}
