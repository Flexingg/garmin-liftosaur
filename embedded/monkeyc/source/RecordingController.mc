// Liftosaur — state machine, sensor polling, chunk emission, ActivityRecording.
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
    STATE_STOPPED    // Stop pressed — set finished, end-of-set flushed
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
//
// Transmit path: frames are handed to a LiftTransport (see Transport.mc). The
// default logs them, which is what makes HW checkpoint 2 verifiable on-device
// before the BLE/HTTP decision (docs/00 §4) is settled.
// ---------------------------------------------------------------------------

// Prompt before writing the activity to Garmin Connect. Set false to save
// automatically again (the pre-debug behaviour).
const PROMPT_SAVE_ON_STOP = true;

class RecordingController {

    private var _state;
    private var _session;   // ActivityRecording.Session
    private var _buffer;    // SampleBuffer
    private var _startMs;   // System.getTimer() at record start (monotonic base)
    private var _lastLogMs; // last periodic console summary
    private var _timer;     // Timer.Timer polling Sensor.getInfo()
    private var _emitTimer; // Timer.Timer draining chunks to the transport
    private var _transport; // LiftTransport
    private var _seq;       // monotonic frame counter (contract 01 header)
    private var _chunksSent;
    private var _exerciseId;

    function initialize() {
        _state      = STATE_INIT;
        _session    = null;
        _buffer     = new SampleBuffer(500);
        _startMs    = 0;
        _lastLogMs  = 0;
        _timer      = null;
        _emitTimer  = null;
        // BLE streaming teed with the console log: the log is the only
        // observability we have on a physical watch, so keep it while streaming.
        _transport  = new LiftTeeTransport([new LiftBleTransport(), new LiftLogTransport()]);
        _seq        = 0;
        _chunksSent = 0;
        _exerciseId = 0;                        // set by CMD frames in Phase 3
    }

    function getState() as Number      { return _state; }
    function getRateHz() as Float      { return _buffer.rateHz(); }
    function getSampleCount() as Number { return _buffer.total(); }
    function getChunksSent() as Number { return _chunksSent; }
    function getPending() as Number    { return _buffer.pendingCount(); }
    function getDropped() as Number    { return _buffer.dropped(); }
    function getTransportName() as String { return _transport.name(); }
    function getFramesSent() as Number   { return _transport.framesSent(); }
    function getWriteFails() as Number   { return _transport.writeFails(); }
    function getWriteStatusName() as String { return _transport.writeStatusName(); }
    function getSkipped() as Number      { return _transport.skipped(); }
    function getAdvertisersSeen() as Number { return _transport.advertisersSeen(); }
    function getScanRestarts() as Number    { return _transport.scanRestarts(); }
    function getPairAttempts() as Number    { return _transport.pairAttempts(); }
    function getTxStatus() as String     { return _transport.statusLine(); }

    // Start polling the accelerometer and move to STATE_IDLE. From App.onStart.
    function start() as Void {
        _timer = new Timer.Timer();
        _timer.start(method(:onSensorTick), 50, true);  // ~20 Hz poll

        _emitTimer = new Timer.Timer();
        _emitTimer.start(method(:onEmitTick), 1000, true);  // ~1 Hz chunk cadence

        _transport.start();
        _state = STATE_IDLE;
        WatchUi.requestUpdate();
        System.println("Liftosaur: polling started, STATE_IDLE, transport=" +
                       _transport.name());
    }

    // Stop the polling timers. From App.onStop.
    function stop() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        if (_emitTimer != null) {
            _emitTimer.stop();
            _emitTimer = null;
        }
        _transport.stop();
        _state = STATE_INIT;
    }

    // Resolve the open FIT session after the save prompt. Called by the
    // Confirmation dialog's delegate. `save` false discards the recording, so a
    // debug run leaves nothing behind in Garmin Connect.
    function finishSet(save as Boolean) as Void {
        if (_session == null) { return; }
        if (save) {
            _session.save();
            System.println("== SESSION SAVED ==");
        } else {
            _session.discard();
            System.println("== SESSION DISCARDED ==");
        }
        _session = null;
        WatchUi.requestUpdate();
    }

    // Hardware Start/Stop button toggle.
    function onToggle() as Void {
        if (_state == STATE_IDLE || _state == STATE_STOPPED) {
            beginRecording();
        } else if (_state == STATE_RECORDING) {
            endRecording();
        }
    }

    // Enter recording: reset buffer, start ActivityRecording session, announce.
    function beginRecording() as Void {
        _buffer.clear();
        _startMs = System.getTimer();
        _seq = 0;
        _chunksSent = 0;

        if (Toybox has :ActivityRecording) {
            // Save this as a STRENGTH WORKOUT, not a generic activity.
            // NOTE: SPORT_STRENGTH_TRAINING does NOT exist on the Venu 2S runtime
            // (it is in the SDK union API only) - strength is expressed as the
            // SPORT_TRAINING + SUB_SPORT_STRENGTH_TRAINING pair instead.
            _session = ActivityRecording.createSession({
                :name     => "Liftosaur",
                :sport    => Activity.SPORT_TRAINING,
                :subSport => Activity.SUB_SPORT_STRENGTH_TRAINING
            });
            _session.start();
        }

        // HELLO announces the true sensor rate to the phone (docs/01 §1).
        _emit(LiftFrame.hello(_seq, _exerciseId, _rateHzInt()));

        _state = STATE_RECORDING;
        _lastLogMs = 0;
        WatchUi.requestUpdate();
        System.println("== RECORDING START ==");
    }

    // Stop recording: flush the tail, emit SET_END, finalize the FIT session.
    function endRecording() as Void {
        var durationMs = _elapsedMs();

        // Final partial chunk, marked with CHUNK_END (docs/01 §5).
        var tail = _buffer.drainPending(255);
        _emit(LiftFrame.chunk(_seq, _exerciseId, _rateHzInt(),
                              LiftFrame.FLAG_CHUNK_END, tail));
        _emit(LiftFrame.setEnd(_seq, _exerciseId, _rateHzInt(), durationMs, 0));

        if ((Toybox has :ActivityRecording) && (_session != null)) {
            // Stop, but do NOT save yet: the set is complete, the FIT session is
            // kept open until the user answers the save prompt. Handy while
            // debugging, since every test run otherwise lands in Garmin Connect.
            _session.stop();
        }

        _state = STATE_STOPPED;
        WatchUi.requestUpdate();
        System.println("== RECORDING STOP == duration_ms=" + durationMs +
                       " chunks=" + _chunksSent + " dropped=" + _buffer.dropped() +
                       " txSkipped=" + _transport.skipped());
        _buffer.logSummary();

        if (PROMPT_SAVE_ON_STOP && (_session != null)) {
            WatchUi.pushView(new WatchUi.Confirmation("Save workout?"),
                             new LiftSaveDelegate(self),
                             WatchUi.SLIDE_UP);
        } else {
            finishSet(PROMPT_SAVE_ON_STOP);
        }
    }

    // Timer tick: read the latest accelerometer sample. Buffer only while recording.
    function onSensorTick() as Void {
        // Link upkeep runs regardless of recording state, so the BLE link can
        // establish (and recover) while the app is just sitting in IDLE.
        _transport.tick();

        if (_state != STATE_RECORDING) {
            return;
        }
        var info = Sensor.getInfo();
        if ((info has :accel) && (info.accel != null)) {
            _buffer.add(info.accel, _startMs);
        }
        var now = System.getTimer();
        if (now - _lastLogMs >= 5000) {
            _lastLogMs = now;
            _buffer.logSummary();
        }
    }

    // ~1 Hz: hand the accumulated samples to the transport as one CHUNK.
    function onEmitTick() as Void {
        if (_state != STATE_RECORDING) {
            return;
        }
        var samples = _buffer.drainPending(255);
        if (samples.size() == 0) {
            return;   // nothing new (sensor stalled or fully de-duplicated)
        }
        _emit(LiftFrame.chunk(_seq, _exerciseId, _rateHzInt(), 0, samples));
    }

    private function _emit(frame as Dictionary) as Void {
        _seq++;
        if (frame["type"] == "chunk") { _chunksSent++; }
        _transport.emit(frame);
    }

    private function _rateHzInt() as Number {
        var r = _buffer.rateHz();
        if (r <= 0.0) { return 0; }
        return r.toNumber();
    }

    private function _elapsedMs() as Long {
        if (_startMs == 0) { return 0l; }
        return System.getTimer() - _startMs;
    }
}

// Yes/No dialog shown when a set stops: writes the FIT recording ("yes") or
// throws it away ("no"). Debugging makes a lot of throwaway activities.
class LiftSaveDelegate extends WatchUi.ConfirmationDelegate {

    private var _controller;

    function initialize(controller as RecordingController) {
        WatchUi.ConfirmationDelegate.initialize();
        _controller = controller;
    }

    // Parameter type is WatchUi.Confirm (the enum type), not WatchUi.Confirmation
    // - the compiler rejects the wrong one with "Cannot override parameter 1".
    function onResponse(response as WatchUi.Confirm) as Boolean {
        _controller.finishSet(response == WatchUi.CONFIRM_YES);
        return true;
    }
}
