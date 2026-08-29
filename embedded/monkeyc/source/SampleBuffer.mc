// Liftosaur — ring buffer for accelerometer samples + console logging.
// Owner: Embedded Agent.
//
// Compact sample store for HW checkpoint 1 (prove 100Hz-ish data flows without
// crashing the watch). Values are Toybox.SensorData.accel arrays: [x,y,z] in
// m/s^2 per Garmin docs. NOTE: verify at checkpoint 1 that a still wrist reads
// |Z| ~ 9.81 (not ~1.0) — if it's ~1.0 the raw units are g and we rescale.
//
// A ring buffer caps memory regardless of set length (drift of long sets).

using Toybox.System as Sys;
using Toybox.Sensor as Sensor;
using Toybox.Lang as Lang;

class SampleBuffer {

    hidden var _cap;    // max buffered samples
    hidden var _count;  // samples currently in window
    hidden var _total;  // cumulative samples across the whole set
    hidden var _xs; hidden var _ys; hidden var _zs; hidden var _elapsedMs;

    function initialize(cap as Number) {
        _cap  = cap;
        _xs = new[cap]; _ys = new[cap]; _zs = new[cap]; _elapsedMs = new[cap];
        _count = 0;
        _total = 0;
    }

    // Store one sample. elapsedMs is System.getTimer() minus the set start,
    // kept small (Number) to avoid Long/32-bit overflow.
    function add(sensorData as Sensor.SensorData, startMs as Long) as Void {
        var a = sensorData.accel;
        if (a == null) { return; }
        var now = Sys.getTimer() - startMs;  // small relative value
        if (_count == _cap) { shift(); }
        var i = _count;
        _xs[i] = a[0]; _ys[i] = a[1]; _zs[i] = a[2]; _elapsedMs[i] = now;
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
        Sys.println("samples total=" + _total + " window=" + _count +
                    " rateHz=" + rateHz().format("%.1f"));
        if (_count > 0) {
            var mid = (_count / 2).toNumber();
            Sys.println("  first t=" + _elapsedMs[0] + " x=" + _xs[0].format("%.2f") +
                        " y=" + _ys[0].format("%.2f") + " z=" + _zs[0].format("%.2f"));
            Sys.println("  mid   t=" + _elapsedMs[mid] + " x=" + _xs[mid].format("%.2f") +
                        " y=" + _ys[mid].format("%.2f") + " z=" + _zs[mid].format("%.2f"));
        }
    }

    function clear() as Void {
        _count = 0;
        _total = 0;
    }
}
