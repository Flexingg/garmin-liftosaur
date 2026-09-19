// Liftosaur Garmin app — workout entry point.
//
// The watch is a STANDALONE gym companion. The plan is fetched from the backend
// over https at launch (docs/06) and falls back to the copy baked into the app
// (source/PlanData.mc) when there is no network, so a workout is never blocked.
//
// Flow:
//   first run            ProgramPicker  -> DayPicker -> SetView
//   later runs           DayPicker      -> SetView
//     SetView            SELECT logs a set; during rest SELECT skips the rest;
//                        on an AMRAP set SELECT confirms the reps completed
//   finish               stop recording, ask save/discard, upload the workout
//
// The BLE streaming experiment is parked, not wired in. See docs/04.

import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class LiftosaurApp extends Application.AppBase {

    private var _controller;
    private var _comms;

    function initialize() {
        AppBase.initialize();
        _controller = new WorkoutController();
        _comms = new LiftComms(_controller);
        _controller.setComms(_comms);
        _controller.setProgram(LiftPlan.program());
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        // Returning users go straight to picking a day; a first-time user picks
        // a program first (the list arrives from the backend a moment later).
        if (_controller.hasChosenProgram()) {
            return [ new ListPickerView(_controller, "day"),
                     new ListPickerDelegate(_controller, "day") ];
        }
        return [ new ListPickerView(_controller, "program"),
                 new ListPickerDelegate(_controller, "program") ];
    }

    function onStart(state as Dictionary?) as Void {
        // Programs list first; the callback then fetches the chosen program's
        // plan. Both are best-effort - the baked-in plan carries the workout.
        _comms.fetchPrograms();
        // Anything that failed to upload last time goes now.
        _comms.retryPending();
        if (_controller.restore()) {
            System.println("LiftWorkout: restored day " + (_controller.selectedDay() + 1) +
                           " at exercise " + (_controller.currentExerciseIndex() + 1));
        }
        WatchUi.requestUpdate();
    }

    // Persist the cursor so a mid-workout exit is recoverable.
    function onStop(state as Dictionary?) as Void {
        if (_controller.isStarted()) {
            _controller.save();
        }
    }
}
