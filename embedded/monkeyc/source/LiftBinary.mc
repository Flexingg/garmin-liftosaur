// Liftosaur — compact BINARY encoder for the watch -> phone contract
// (docs/01 §2, §3, §5) plus BLE fragmenting.
//
// Why binary: a 1-second CHUNK at 20 Hz is 24 + 20*3*2 = 144 bytes binary vs
// ~400 bytes of JSON, and docs/01 makes the binary form the BLE contract.
//
// This MUST stay byte-identical to the Dart decoder in
// mobile/flutter/lib/binary_frames.dart, which is pinned by golden vectors in
// test/binary_frames_test.dart. Little-endian throughout.
//
// The transport-level fragment header is 4 bytes, matching the Dart
// FrameReassembler:  u16 totalLength (LE) | u8 fragmentIndex | u8 fragmentCount

import Toybox.Lang;

module LiftBinary {

    const HEADER_BYTES = 24;
    const MAGIC_0 = 0x46;   // 0x4C46 ("LF") little-endian
    const MAGIC_1 = 0x4C;
    const FRAGMENT_HEADER_BYTES = 4;
    const CHANNEL_MASK_XYZ = 0x07;

    function typeCode(type as String) as Number {
        if (type == "hello")   { return 0; }
        if (type == "chunk")   { return 1; }
        if (type == "set_end") { return 2; }
        if (type == "cmd")     { return 3; }
        return 255;
    }

    // ByteArray elements are bytes, and Monkey C's % keeps the sign of the
    // dividend, so normalise explicitly instead of relying on truncation.
    function _byte(v as Number) as Number {
        var u = v % 256;
        if (u < 0) { u += 256; }
        return u;
    }

    function _putU16(b as ByteArray, off as Number, v as Number) as Void {
        b[off]     = _byte(v);
        b[off + 1] = _byte(v / 256);
    }

    function _putU32(b as ByteArray, off as Number, v as Number) as Void {
        b[off]     = _byte(v);
        b[off + 1] = _byte(v / 256);
        b[off + 2] = _byte(v / 65536);
        b[off + 3] = _byte(v / 16777216);
    }

    // Two's-complement int16 (samples can be negative).
    function _putI16(b as ByteArray, off as Number, v as Number) as Void {
        var u = v;
        if (u < 0) { u = u + 65536; }
        _putU16(b, off, u);
    }

    function _putI64(b as ByteArray, off as Number, v as Long) as Void {
        var x = v;
        for (var i = 0; i < 8; i++) {
            // x % 256 is a Long; _byte() works in Number, so narrow explicitly.
            b[off + i] = _byte((x % 256).toNumber());
            x = x / 256;
        }
    }

    // Encode one contract frame (as built by LiftFrame) to its binary form.
    function encode(frame as Dictionary) as ByteArray {
        var type = frame["type"];
        var isChunk = (type == "chunk");
        var isSetEnd = (type == "set_end");
        var samples = isChunk ? frame["samples"] : [];
        var n = samples.size();

        var bodyBytes = 0;
        if (isChunk) { bodyBytes = 5 + (n * 3 * 2); }
        else if (isSetEnd) { bodyBytes = 5; }

        var b = new[HEADER_BYTES + bodyBytes] as ByteArray;
        b[0] = MAGIC_0;
        b[1] = MAGIC_1;
        b[2] = 1;                          // protocol version (docs/01 §2)
        b[3] = typeCode(type);
        _putU32(b, 4, frame["seq"]);
        _putI64(b, 8, frame["ts"]);
        _putU16(b, 16, frame["exercise_id"]);
        b[18] = _byte(frame["rate_hz"]);
        b[19] = _byte(frame["flags"]);
        _putU32(b, 20, 0);                 // reserved

        var o = HEADER_BYTES;
        if (isChunk) {
            _putU16(b, o, n);
            b[o + 2] = CHANNEL_MASK_XYZ;
            _putI16(b, o + 3, frame["scale"]);
            o = o + 5;
            for (var i = 0; i < n; i++) {
                var row = samples[i];
                _putI16(b, o,     row[0]);
                _putI16(b, o + 2, row[1]);
                _putI16(b, o + 4, row[2]);
                o = o + 6;
            }
        } else if (isSetEnd) {
            _putU32(b, o, frame["duration_ms"]);
            b[o + 4] = _byte(frame["rep_hint"]);
        }
        return b;
    }

    // Split a frame into <= maxPayload-byte fragments, each with the 4-byte
    // header the Dart FrameReassembler expects.
    function fragment(frame as ByteArray, maxPayload as Number) as Array {
        if (maxPayload <= 0) { maxPayload = 20; }
        var total = frame.size();
        var count = ((total + maxPayload - 1) / maxPayload).toNumber();
        if (count < 1) { count = 1; }
        var out = [];
        for (var i = 0; i < count; i++) {
            var start = i * maxPayload;
            var end = start + maxPayload;
            if (end > total) { end = total; }
            var len = end - start;
            var f = new[FRAGMENT_HEADER_BYTES + len] as ByteArray;
            _putU16(f, 0, total);
            f[2] = _byte(i);
            f[3] = _byte(count);
            for (var k = 0; k < len; k++) {
                f[FRAGMENT_HEADER_BYTES + k] = frame[start + k];
            }
            out.add(f);
        }
        return out;
    }
}
