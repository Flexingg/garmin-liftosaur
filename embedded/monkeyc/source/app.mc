// Liftosaur Garmin app (Venu 2) — Phase 1: core UI + sensor listener.
// Owner: Embedded Agent.
//
// App entry point. Creates the RecordingController (state machine + sensor +
// ActivityRecording) and wires it to the view and input delegate.

using Toybox.Application as App;
using Toybox.System as Sys;
using Toybox.Sensor as Sensor;

class LiftosaurApp extends App.AppBase {

    hidden var _controller;

    function initialize() {
        AppBase.initialize();
        _controller = new RecordingController();
    }

    // Set the app's initial view + input delegate.
    function getInitialView() {
        return [ new LiftView(_controller), new LiftDelegate(_controller) ];
    }

    // App fully launched — acquire sensors and go to STATE_IDLE.
    function onStart(state as Dictionary) {
        _controller.start();
    }

    // App closing — release sensor resources.
    function onStop(state as Dictionary) {
        _controller.stop();
    }
}
