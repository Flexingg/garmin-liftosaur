// Liftosaur — ring buffer for accelerometer samples + a drainable pending queue.
// Owner: Embedded Agent.
//
// Two structures, deliberately separate:
//   1. the RING window (capped) — backs the live UI and the true-rate estimate;
//   2. the PENDING queue — every sample not yet handed to the transport. The
//      controller drains it ~1x/second into a CHUNK frame (docs/01 §3).
//
// Storing samples ([x,y,z] Array<Float>) in a ring caps memory regardless of
// set length; the pending queue is bounded too, and overflow is COUNTED rather
// than silently dropped so a slow transport is visible (HW checkpoint 2).
//
// Identical consecutive reads are de-duplicated so the reported rate reflects
// the TRUE sensor rate, not the 50 ms poll rate.
// Units: Garmin reports accel in m/s^2 (verify |Z| ~ 9.81 at rest; if ~1.0 the
// units are g and we rescale in the physics phase).

import Toybox.Lang;
import Toybox.System;

class SampleBuffer {

    private var _cap;    // max buffered samples in the ring window
    private var _count;  // samples currently in the window
    private var _total;  // cumulative samples across the whole set
    private var _xs; private var _ys; private var _zs; private var _elapsedMs;

    // Pending (not yet transmitted) samples.
    private var _pendCap;
    private var _pend;   // count of pending samples
    private var _pXs; private var _pYs; private var _pZs; private var _pTs;
    private var _dropped; // samples lost to pending-queue overflow

    function initialize(cap as Number) {
        _cap  = cap;
        _xs = new[cap]; _ys = new[cap]; _zs = new[cap]; _elapsedMs = new[cap];
        _count = 0;
        _total = 0;

        // ~25 s of headroom at 20 Hz; one second is drained at a time.
        _pendCap = 512;
        _pXs = new[_pendCap]; _pYs = new[_pendCap]; _pZs = new[_pendCap];
        _pTs = new[_pendCap];
        _pend = 0;
        _dropped = 0;
    }

    // Store one sample. startMs is System.getTimer() at set start, kept small
    // (Number) to avoid Long/32-bit overflow.
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

        pushPending(accel, now);
    }

    // Append to the pending queue, dropping the OLDEST sample on overflow and
    // counting the loss (better to lose the oldest than the freshest data).
    private function pushPending(accel as Array<Float>, tMs as Long) as Void {
        if (_pend == _pendCap) {
            for (var i = 1; i < _pendCap; i++) {
                _pXs[i-1] = _pXs[i]; _pYs[i-1] = _pYs[i];
                _pZs[i-1] = _pZs[i]; _pTs[i-1] = _pTs[i];
            }
            _pend--;
            _dropped++;
        }
        _pXs[_pend] = accel[0]; _pYs[_pend] = accel[1]; _pZs[_pend] = accel[2];
        _pTs[_pend] = tMs;
        _pend++;
    }

    // Drop the oldest sample from the ring window to make room.
    function shift() as Void {
        for (var i = 1; i < _cap; i++) {
            _xs[i-1] = _xs[i]; _ys[i-1] = _ys[i]; _zs[i-1] = _zs[i];
            _elapsedMs[i-1] = _elapsedMs[i];
        }
        _count--;
    }

    function count() as Number { return _count; }
    function total() as Number { return _total; }
    function pendingCount() as Number { return _pend; }
    function dropped() as Number { return _dropped; }

    // Take up to maxN pending samples off the queue, oldest first.
    // Returns an Array of [x, y, z] Arrays — the shape LiftFrame.chunk expects.
    function drainPending(maxN as Number) as Array {
        var take = _pend;
        if (take > maxN) { take = maxN; }
        var out = new[take];
        for (var i = 0; i < take; i++) {
            out[i] = [_pXs[i], _pYs[i], _pZs[i]];
        }
        // Slide the remainder down.
        var rest = _pend - take;
        for (var i = 0; i < rest; i++) {
            _pXs[i] = _pXs[i + take]; _pYs[i] = _pYs[i + take];
            _pZs[i] = _pZs[i + take]; _pTs[i] = _pTs[i + take];
        }
        _pend = rest;
        return out;
    }

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
                    " pending=" + _pend + " dropped=" + _dropped +
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
        _pend = 0;
        _dropped = 0;
    }
}
