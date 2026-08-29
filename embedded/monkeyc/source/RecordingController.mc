// Liftosaur — state machine, sensor polling, and ActivityRecording.
// Owner: Embedded Agent.

import Toybox.Lang;
import Toybox.System;
import Toybox.Sensor;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Timer;
import Toybox.WatchUi;

// The watch app's lifecycle states (contract: docs/00 section 2).
enum LiftState {
    STATE_INIT,      // sensors acquired, waiting for Start
    STATE_IDLE,      // ready — shows prescribed exercise/weight (Phase 3)
    STATE_RECORDING, // Start pressed — sensor polling + ActivityRecording active
    STATE_STOPPED    // Stop pressed — set finished, end-of-set flush (Phase 2)
}

// ---------------------------------------------------------------------------
// SAMPLE RATE — the reality (confirmed with Jonathan, validated against SDK 9.2)
// Garmin's public Toybox.Sensor API caps the accelerometer well below 100 Hz:
//   - Sensor.enableSensorEvents(...)  -> delivers data at ONLY 1 Hz (per SDK docs)
//   - Sensor.getInfo().accel on a timer -> the reference AccelMag sample uses a
//     100 ms timer, i.e. ~10 Hz.
// There is NO SENSOR_ACCELEROMETER constant or registerForData() in SDK 9.2.
// We therefore poll Sensor.getInfo().accel on a 50 ms timer (~20 Hz nominal) and
// de-duplicate identical reads to report the TRUE sensor rate. Every downstream
// chunk carries the real rate_hz (contract 01); do not assume 100 Hz.
// ---------------------------------------------------------------------------

class RecordingController {

    private var _state;
    private var _session;   // ActivityRecording.Session
    private var _buffer;    // SampleBuffer
    private var _startMs;   // System.getTimer() at record start (monotonic base)
    private var _lastLogMs; // last per-second console log time
    private var _timer;     // Timer.Timer polling Sensor.getInfo()

    function initialize() {
        _state     = STATE_INIT;
        _session   = null;
        _buffer    = new SampleBuffer(500);
        _startMs   = 0;
        _lastLogMs = 0;
        _timer     = null;
    }

    function getState() as Number      { return _state; }
    function getRateHz() as Float       { return _buffer.rateHz(); }
    function getSampleCount() as Number { return _buffer.total(); }

    // Start polling the accelerometer and move to STATE_IDLE. From App.onStart.
    function start() as Void {
        _timer = new Timer.Timer();
        _timer.start(method(:onSensorTick), 50, true);  // ~20 Hz poll
        _state = STATE_IDLE;
        WatchUi.requestUpdate();
        System.println("Liftosaur: sensor polling started, STATE_IDLE");
    }

    // Stop the polling timer. From App.onStop.
    function stop() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        _state = STATE_INIT;
    }

    // Hardware Start/Stop button toggle.
    function onToggle() as Void {
        if (_state == STATE_IDLE || _state == STATE_STOPPED) {
            beginRecording();
        } else if (_state == STATE_RECORDING) {
            endRecording();
        }
    }

    // Enter recording: reset buffer, start ActivityRecording session.
    function beginRecording() as Void {
        _buffer.clear();
        _startMs = System.getTimer();
        if (Toybox has :ActivityRecording) {
            _session = ActivityRecording.createSession({
                :name  => "Liftosaur",
                :sport => Activity.SPORT_GENERIC
            });
            _session.start();
        }
        _state = STATE_RECORDING;
        _lastLogMs = 0;
        WatchUi.requestUpdate();
        System.println("== RECORDING START ==");
    }

    // Stop recording: finalize the FIT session and log a summary for HW checkpoint 1.
    function endRecording() as Void {
        if ((Toybox has :ActivityRecording) && (_session != null)) {
            _session.stop();
            _session.save();
            _session = null;
        }
        _state = STATE_STOPPED;
        WatchUi.requestUpdate();
        System.println("== RECORDING STOP ==");
        _buffer.logSummary();
    }

    // Timer tick: read the latest accelerometer sample. Buffer only while recording.
    function onSensorTick() as Void {
        if (_state != STATE_RECORDING) {
            return;
        }
        var info = Sensor.getInfo();
        if ((info has :accel) && (info.accel != null)) {
            _buffer.add(info.accel, _startMs);
        }
        var now = System.getTimer();
        if (now - _lastLogMs >= 1000) {
            _lastLogMs = now;
            _buffer.logSummary();
        }
    }
}
