// Liftosaur Garmin app — workout entry point.
//
// The app is a STANDALONE gym companion: the plan is baked in at build time
// (source/PlanData.mc, generated from the user's Liftosaur program by
// tools/plan_from_liftosaur.py), so no BLE and no network are needed to train.
//
// Flow: DayPickerView -> SetView (select logs a set, up/down adjusts weight,
// rest counts down and vibrates) -> finish -> save/discard the activity.
//
// The BLE streaming experiment is parked, not wired in. See docs/04.

import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class LiftosaurApp extends Application.AppBase {

    private var _controller;

    function initialize() {
        AppBase.initialize();
        _controller = new WorkoutController();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new DayPickerView(_controller), new DayPickerDelegate(_controller) ];
    }

    // Offer to resume an interrupted workout instead of losing it.
    function onStart(state as Dictionary?) as Void {
        if (_controller.restore()) {
            System.println("LiftWorkout: restored day " + (_controller.selectedDay() + 1) +
                           " at exercise " + (_controller.currentExerciseIndex() + 1));
        }
    }

    // Persist the cursor so a mid-workout exit is recoverable.
    function onStop(state as Dictionary?) as Void {
        if (_controller.isStarted()) {
            _controller.save();
        }
    }
}
