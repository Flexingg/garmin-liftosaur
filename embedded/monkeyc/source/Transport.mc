// Liftosaur — transport seam for watch -> phone frames.
// Owner: Embedded Agent.
//
// Frames are handed to a LiftTransport so the delivery mechanism stays
// swappable. Current implementations:
//
//   LiftLogTransport  — writes the contract frame to the device console. This
//                       is the only observability we have on a physical watch,
//                       so it stays in the default stack.
//   LiftBleTransport  — BLE central -> the phone's GATT server (see that file
//                       for the role-inversion explanation and its STATUS note).
//
// The default is a TEE of both: logs every frame AND streams it over BLE, so
// Hardware Checkpoint 2 can be checked against the device log even when the
// phone link is misbehaving.

import Toybox.Lang;
import Toybox.System;

class LiftTransport {

    // Deliver one contract frame. Base class is a no-op.
    function emit(frame as Dictionary) as Void {
    }

    // Acquire/release any connection resources. No-ops by default.
    function start() as Void {
    }

    function stop() as Void {
    }

    // Human-readable name for the UI/debug.
    function name() as String {
        return "null";
    }

    function framesSent() as Number {
        return 0;
    }

    function writeFails() as Number {
        return 0;
    }

    // Frames the transport could not send because the link was not ready.
    // This is the counter that was missing when the watch showed "sent=0" and
    // "fail=0" with nothing arriving: emit() silently returned.
    function skipped() as Number {
        return 0;
    }

    // Short on-screen description of WHY the link is in its current state.
    function statusLine() as String {
        return "n/a";
    }

    // Periodic link maintenance (reconnect/watchdog). Called from the sensor
    // tick so it runs whether or not a set is recording.
    function tick() as Void {
    }

    // Advertisements seen while scanning. 0 while "scan" means the watch is not
    // seeing any BLE traffic at all; >0 but never connecting is the signature of
    // "advertisements arrive, but none is ours".
    function advertisersSeen() as Number {
        return 0;
    }

    // Times a blind scan (scanning but hearing nothing) was cycled to recover.
    function scanRestarts() as Number {
        return 0;
    }

    // How many times the link has paired with the peer.
    function pairAttempts() as Number {
        return 0;
    }
}

// Logs the frame. Used for HW checkpoint validation and as a fallback.
class LiftLogTransport extends LiftTransport {

    private var _frames;

    function initialize() {
        LiftTransport.initialize();
        _frames = 0;
    }

    function emit(frame as Dictionary) as Void {
        _frames++;
        System.println(LiftFrame.toLogLine(frame) + " frames=" + _frames);
    }

    function name() as String {
        return "log";
    }

    function framesSent() as Number {
        return _frames;
    }

    function statusLine() as String {
        return "log";
    }
}

// Fan a frame out to several transports. Used to keep the console log alive
// alongside BLE streaming.
class LiftTeeTransport extends LiftTransport {

    private var _parts;

    function initialize(parts as Array) {
        LiftTransport.initialize();
        _parts = parts;
    }

    function start() as Void {
        for (var i = 0; i < _parts.size(); i++) {
            _parts[i].start();
        }
    }

    function stop() as Void {
        for (var i = 0; i < _parts.size(); i++) {
            _parts[i].stop();
        }
    }

    function emit(frame as Dictionary) as Void {
        for (var i = 0; i < _parts.size(); i++) {
            _parts[i].emit(frame);
        }
    }

    function name() as String {
        var s = "";
        for (var i = 0; i < _parts.size(); i++) {
            if (i > 0) { s = s + "+"; }
            s = s + _parts[i].name();
        }
        return s;
    }

    // Report the FIRST transport's counters (the primary link, i.e. BLE).
    function framesSent() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].framesSent();
    }

    function writeFails() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].writeFails();
    }

    function skipped() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].skipped();
    }

    // The FIRST transport is the real link (BLE); report its state on screen.
    function statusLine() as String {
        if (_parts.size() == 0) { return "none"; }
        return _parts[0].statusLine();
    }

    function tick() as Void {
        for (var i = 0; i < _parts.size(); i++) {
            _parts[i].tick();
        }
    }

    function advertisersSeen() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].advertisersSeen();
    }

    function scanRestarts() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].scanRestarts();
    }

    function pairAttempts() as Number {
        if (_parts.size() == 0) { return 0; }
        return _parts[0].pairAttempts();
    }
}
