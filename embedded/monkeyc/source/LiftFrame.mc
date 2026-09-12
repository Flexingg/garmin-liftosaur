// Liftosaur — wire frames for the watch -> phone contract (docs/01).
// Owner: Embedded Agent.
//
// Implements the dictionary/JSON form of the payload contract (docs/01 §7),
// which is what `Toybox.Communications.transmit` sends and what the Dart side
// decodes. Kept deliberately free of any transport dependency so the app stays
// buildable/sideloadable while the Phase 2 transport decision is open.
//
// SCALE follows docs/01 §3: raw int16 == accel_m_s2 * SCALE. 1000 gives 1 mm/s^2
// resolution and +/-32.7 m/s^2 range.

import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

module LiftFrame {

    const PROTOCOL_VERSION = 1;

    const TYPE_HELLO   = 0;
    const TYPE_CHUNK   = 1;
    const TYPE_SET_END = 2;
    const TYPE_CMD     = 3;

    // docs/01 §2 header flags
    const FLAG_CHUNK_END     = 0x01;
    const FLAG_GRAVITY_KNOWN = 0x02;

    const SCALE = 1000;

    function typeName(type as Number) as String {
        if (type == TYPE_HELLO)   { return "hello"; }
        if (type == TYPE_CHUNK)   { return "chunk"; }
        if (type == TYPE_SET_END) { return "set_end"; }
        if (type == TYPE_CMD)     { return "cmd"; }
        return "unknown";
    }

    // Epoch ms. Time.now().value() is whole seconds; System.getTimer() (ms since
    // boot) adds sub-second resolution. Consumers must not assume better than
    // rate_hz spacing between samples regardless (docs/01 §4).
    //
    // Must be Long: epoch-ms is ~1.7e12, which overflows a 32-bit Monkey C
    // Number. Doing `secs * 1000` in Number arithmetic silently produced a
    // garbage timestamp before this was fixed.
    function epochMs() as Long {
        var secs = Time.now().value();
        var subMs = System.getTimer() % 1000;
        return (secs.toLong() * 1000) + subMs;
    }

    // Shared header fields (docs/01 §2).
    function header(seq as Number, type as Number, exerciseId as Number,
                    rateHz as Number, flags as Number) as Dictionary {
        return {
            "v"           => PROTOCOL_VERSION,
            "type"        => typeName(type),
            "seq"         => seq,
            "ts"          => epochMs(),
            "exercise_id" => exerciseId,
            "rate_hz"     => rateHz,
            "flags"       => flags
        };
    }

    // HELLO — announces capability + the TRUE sample rate on connect (docs/01 §1).
    function hello(seq as Number, exerciseId as Number, rateHz as Number) as Dictionary {
        var f = header(seq, TYPE_HELLO, exerciseId, rateHz, 0);
        f.put("channels", ["x", "y", "z"]);
        f.put("scale", SCALE);
        f.put("chunk_target_ms", 1000);
        f.put("capabilities", {
            "activity_recording" => (Toybox has :ActivityRecording)
        });
        return f;
    }

    // CHUNK — ~1 s of samples, X/Y/Z interleaved and scaled to int16 (docs/01 §3).
    // `samples` is an Array of [x, y, z] m/s^2 Floats straight from SampleBuffer.
    function chunk(seq as Number, exerciseId as Number, rateHz as Number,
                   flags as Number, samples as Array) as Dictionary {
        var n = samples.size();
        var out = new[n];
        for (var i = 0; i < n; i++) {
            var s = samples[i];
            out[i] = [ (s[0] * SCALE).toNumber(),
                       (s[1] * SCALE).toNumber(),
                       (s[2] * SCALE).toNumber() ];
        }
        var f = header(seq, TYPE_CHUNK, exerciseId, rateHz, flags);
        f.put("sample_count", n);
        f.put("channels", ["x", "y", "z"]);
        f.put("scale", SCALE);
        f.put("samples", out);
        return f;
    }

    // SET_END — set finished; flags.bit0 (CHUNK_END) must be set (docs/01 §5).
    function setEnd(seq as Number, exerciseId as Number, rateHz as Number,
                    durationMs as Long, repHint as Number) as Dictionary {
        var f = header(seq, TYPE_SET_END, exerciseId, rateHz, FLAG_CHUNK_END);
        f.put("duration_ms", durationMs);
        f.put("rep_hint", repHint);
        return f;
    }

    // Compact one-line rendering for the device console (HW checkpoint logging).
    // Deliberately truncates samples — the full frame is the dictionary above.
    function toLogLine(frame as Dictionary) as String {
        var s = "[LF] " + frame["type"] + " seq=" + frame["seq"] +
                " rate=" + frame["rate_hz"] + " flags=" + frame["flags"];
        if (frame.hasKey("sample_count")) {
            s = s + " n=" + frame["sample_count"];
            var samples = frame["samples"];
            var n = samples.size();
            if (n > 0) {
                var a = samples[0];
                s = s + " first=[" + a[0] + "," + a[1] + "," + a[2] + "]";
                if (n > 1) {
                    var b = samples[1];
                    s = s + " second=[" + b[0] + "," + b[1] + "," + b[2] + "]";
                }
            }
        }
        if (frame.hasKey("duration_ms")) {
            s = s + " dur=" + frame["duration_ms"];
        }
        return s;
    }
}
