// Liftosaur — ring buffer for accelerometer samples + console logging.
// Owner: Embedded Agent.
//
// Stores Toybox.Sensor.getInfo().accel samples ([x,y,z] Array<Float>). A ring
// buffer caps memory regardless of set length. Identical consecutive reads are
// de-duplicated so the reported rate reflects the TRUE sensor rate, not the
// poll rate. Units: Garmin reports accel in m/s^2 (verify |Z| ~ 9.81 at rest;
// if ~1.0 the units are g and we rescale in the physics phase).

import Toybox.Lang;
import Toybox.System;

class SampleBuffer {

    private var _cap;    // max buffered samples
    private var _count;  // samples currently in window
    private var _total;  // cumulative samples across the whole set
    private var _xs; private var _ys; private var _zs; private var _elapsedMs;

    function initialize(cap as Number) {
        _cap  = cap;
        _xs = new[cap]; _ys = new[cap]; _zs = new[cap]; _elapsedMs = new[cap];
        _count = 0;
        _total = 0;
    }

    // Store one sample. elapsedMs is System.getTimer() minus the set start,
    // kept small (Number) to avoid Long/32-bit overflow.
    function add(accel as Array<Float>, startMs as Long) as Void {
        if (accel == null) { return; }
        var now = System.getTimer() - startMs;  // small relative value

        // De-duplicate: identical consecutive reads are the cached sample
        // returned by getInfo() between actual sensor updates.
        if (_count > 0) {
            if (_xs[_count-1] == accel[0] && _ys[_count-1] == accel[1] &&
                _zs[_count-1] == accel[2]) {
                return;
            }
        }

        if (_count == _cap) { shift(); }
        var i = _count;
        _xs[i] = accel[0]; _ys[i] = accel[1]; _zs[i] = accel[2]; _elapsedMs[i] = now;
        _count++;
        _total++;
    }

    // Drop the oldest sample to make room (ring behavior).
    function shift() as Void {
        for (var i = 1; i < _cap; i++) {
            _xs[i-1] = _xs[i]; _ys[i-1] = _ys[i]; _zs[i-1] = _zs[i];
            _elapsedMs[i-1] = _elapsedMs[i];
        }
        _count--;
    }

    function count() as Number { return _count; }
    function total() as Number { return _total; }

    // Estimated sample rate over the buffered window, in Hz.
    function rateHz() as Float {
        if (_count < 2) { return 0.0; }
        var dtMs = _elapsedMs[_count-1] - _elapsedMs[0];
        if (dtMs <= 0) { return 0.0; }
        return (_count - 1) * 1000.0 / dtMs;
    }

    // Console summary — the HW checkpoint 1 validation output.
    function logSummary() as Void {
        System.println("samples total=" + _total + " window=" + _count +
                    " rateHz=" + rateHz().format("%.1f"));
        if (_count > 0) {
            var mid = (_count / 2).toNumber();
            System.println("  first t=" + _elapsedMs[0] + " x=" + _xs[0].format("%.2f") +
                        " y=" + _ys[0].format("%.2f") + " z=" + _zs[0].format("%.2f"));
            System.println("  mid   t=" + _elapsedMs[mid] + " x=" + _xs[mid].format("%.2f") +
                        " y=" + _ys[mid].format("%.2f") + " z=" + _zs[mid].format("%.2f"));
        }
    }

    function clear() as Void {
        _count = 0;
        _total = 0;
    }
}
