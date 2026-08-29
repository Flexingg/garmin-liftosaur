// Liftosaur — state machine, sensor listener, and ActivityRecording.
// Owner: Embedded Agent.

using Toybox.System as Sys;
using Toybox.Sensor as Sensor;
using Toybox.ActivityRecording as ActivityRec;
using Toybox.WatchUi as Ui;

// The watch app's lifecycle states (contract: docs/00 section 2).
enum LiftState {
    STATE_INIT,      // sensors acquired, waiting for Start
    STATE_IDLE,      // ready — shows prescribed exercise/weight (Phase 3)
    STATE_RECORDING, // Start pressed — sensors + ActivityRecording active
    STATE_STOPPED    // Stop pressed — set finished, end-of-set flush (Phase 2)
}

// ---------------------------------------------------------------------------
// NOTE ON SAMPLE RATE (design decision confirmed with Jonathan)
// Garmin's public Toybox.Sensor API does NOT let us choose 100 Hz. On the Venu 2
// the effective accelerometer callback rate is roughly 10-25 Hz. We sample at
// "max available rate", stamp our own monotonic clock, and report the real
// rate_hz with each chunk (contract 01). Do not assume 100 Hz anywhere downstream.
// ---------------------------------------------------------------------------

class RecordingController {

    hidden var _state;
    hidden var _session;   // ActivityRecording.Session
    hidden var _buffer;    // SampleBuffer
    hidden var _startMs;   // System.getTimer() at record start (monotonic base)
    hidden var _lastLogMs; // last per-second console log time

    function initialize() {
        _state     = LiftState.STATE_INIT;
        _session   = null;
        _buffer    = new SampleBuffer(200);
        _startMs   = 0;
        _lastLogMs = 0;
    }

    function getState() as LiftState      { return _state; }
    function getRateHz() as Float         { return _buffer.rateHz(); }
    function getSampleCount() as Number   { return _buffer.total(); }

    // Acquire the accelerometer and move to STATE_IDLE. Called from App.onStart.
    function start() as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_ACCELEROMETER]);
        Sensor.registerForData(method(:onSensorData));
        _state = LiftState.STATE_IDLE;
        Ui.requestUpdate();
        Sys.println("Liftosaur: sensors enabled, STATE_IDLE");
    }

    // Release the sensor listener. Called from App.onStop.
    function stop() as Void {
        Sensor.unregisterForData(method(:onSensorData));
        _state = LiftState.STATE_INIT;
    }

    // Hardware Start/Stop button toggle.
    function onToggle() as Void {
        if (_state == LiftState.STATE_IDLE || _state == LiftState.STATE_STOPPED) {
            beginRecording();
        } else if (_state == LiftState.STATE_RECORDING) {
            endRecording();
        }
    }

    // Enter recording: reset buffer, start ActivityRecording session.
    function beginRecording() as Void {
        _buffer.clear();
        _startMs = Sys.getTimer();
        // TODO: set :subSport => Activity.SUB_SPORT_WEIGHT_TRAINING if desired.
        _session = new ActivityRec.Session({:sport => ActivityRec.SPORT_GENERIC});
        _session.start();
        _state = LiftState.STATE_RECORDING;
        _lastLogMs = 0;
        Ui.requestUpdate();
        Sys.println("== RECORDING START ==");
    }

    // Stop recording: finalize the FIT session and log a summary for HW checkpoint 1.
    function endRecording() as Void {
        if (_session != null) {
            _session.stop();
            _session.save();
            _session = null;
        }
        _state = LiftState.STATE_STOPPED;
        Ui.requestUpdate();
        Sys.println("== RECORDING STOP ==");
        _buffer.logSummary();
    }

    // Sensor callback. Only buffer while recording. Log a 1 Hz console summary.
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        if (_state != LiftState.STATE_RECORDING) {
            return;
        }
        _buffer.add(sensorData, _startMs);
        var now = Sys.getTimer();
        if (now - _lastLogMs >= 1000) {
            _lastLogMs = now;
            _buffer.logSummary();
        }
    }
}
