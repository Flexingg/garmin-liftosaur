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
}
