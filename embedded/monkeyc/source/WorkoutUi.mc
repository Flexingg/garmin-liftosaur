// Liftosaur watch workout — views and input.
//
// Two screens:
//   DayPickerView  choose which program day to train (the plan's day names)
//   SetView        the workout itself: exercise, target weight x reps, rest clock
//
// Input on the Venu 2S (5-button):
//   SELECT        complete the set / start the workout
//   UP / DOWN     adjust the current set's weight by 5 lb
//   BACK          leave (the activity prompt handles save/discard)
//
// Reps are shown as the target for now; editing reps (for the AMRAP set) is a
// follow-up - it needs a press/long-press scheme verified on hardware.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class DayPickerView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        dc.drawText(w / 2, 24, Graphics.FONT_XTINY, "LIFTOSAUR",
                    Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, 42, Graphics.FONT_XTINY, _c.section(),
                    Graphics.TEXT_JUSTIFY_CENTER);

        var n = _c.dayCount();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2 - 30, Graphics.FONT_MEDIUM,
                    "Day " + (_c.selectedDay() + 1) + "/" + n,
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.drawText(w / 2, h / 2 + 6, Graphics.FONT_SMALL,
                    _c.dayName(_c.selectedDay()),
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2 + 34, Graphics.FONT_XTINY,
                    _c.dayExerciseCount(_c.selectedDay()) + " exercises, " +
                    _c.daySetCount(_c.selectedDay()) + " sets",
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.drawText(w / 2, h - 28, Graphics.FONT_XTINY,
                    "up/down day    start \u25b6", Graphics.TEXT_JUSTIFY_CENTER);
    }
}

class DayPickerDelegate extends WatchUi.InputDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        InputDelegate.initialize();
        _c = c;
    }

    function onNextPage() as Boolean {
        _c.selectDay((_c.selectedDay() + 1) % _c.dayCount());
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        var n = _c.dayCount();
        _c.selectDay((_c.selectedDay() + n - 1) % n);
        WatchUi.requestUpdate();
        return true;
    }

    function onSelect() as Boolean {
        _c.startWorkout();
        WatchUi.pushView(new SetView(_c), new SetDelegate(_c), WatchUi.SLIDE_LEFT);
        return true;
    }
}

class SetView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    private function fmtMs(ms as Number) as String {
        var t = ms / 1000;
        var m = t / 60;
        var s = t % 60;
        return m.format("%d") + ":" + s.format("%02d");
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // rest takes over the screen: that is what the user is waiting on
        if (_c.isResting()) {
            dc.drawText(w / 2, 30, Graphics.FONT_XTINY, "REST",
                        Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(w / 2, h / 2 - 40, Graphics.FONT_NUMBER_HOT,
                        _c.restRemaining().format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 + 20, Graphics.FONT_SMALL,
                        "of " + _c.restTotal() + "s", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(w / 2, h - 56, Graphics.FONT_XTINY,
                        "next: " + _c.currentExerciseName() + " " +
                        _c.currentSetNumber() + "/" + _c.currentExerciseSetCount(),
                        Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(w / 2, h - 30, Graphics.FONT_XTINY,
                        "select = done now", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        if (_c.isFinished()) {
            dc.drawText(w / 2, h / 2 - 50, Graphics.FONT_MEDIUM, "SESSION DONE",
                        Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(w / 2, h / 2, Graphics.FONT_SMALL,
                        _c.setsDone() + "/" + _c.setsTotal() + " sets logged",
                        Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2 + 30, Graphics.FONT_XTINY,
                        "elapsed " + fmtMs(_c.elapsedMs()), Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(w / 2, h - 30, Graphics.FONT_XTINY,
                        "select = finish", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // header: progress + day
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 16, Graphics.FONT_XTINY,
                    _c.dayName(_c.selectedDay()) + "   " + _c.setsDone() + "/" +
                    _c.setsTotal() + " sets", Graphics.TEXT_JUSTIFY_CENTER);

        // exercise name, wrapped by hand for long names
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var name = _c.currentExerciseName();
        if (name.length() > 22) {
            var cut = name.find(" ");
            dc.drawText(w / 2, h / 2 - 74, Graphics.FONT_SMALL,
                        cut == null ? name : name.substring(0, cut),
                        Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(w / 2, h / 2 - 74, Graphics.FONT_SMALL, name,
                        Graphics.TEXT_JUSTIFY_CENTER);
        }

        // the target: weight x reps
        dc.drawText(w / 2, h / 2 - 42, Graphics.FONT_NUMBER_MEDIUM,
                    _c.currentWeight().format("%d") + " lb",
                    Graphics.TEXT_JUSTIFY_CENTER);
        var reps = _c.currentReps().format("%d") + (_c.currentAmrap() ? "+" : "");
        dc.drawText(w / 2, h / 2 + 6, Graphics.FONT_MEDIUM, "x " + reps,
                    Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2 + 44, Graphics.FONT_XTINY,
                    "set " + _c.currentSetNumber() + "/" + _c.currentExerciseSetCount() +
                    "   rest " + _c.currentRest() + "s", Graphics.TEXT_JUSTIFY_CENTER);

        var bar = "";
        if (_c.isCurrentLogged()) { bar = "logged - select for next"; }
        else { bar = "select = done    up/down = weight"; }
        dc.drawText(w / 2, h - 58, Graphics.FONT_XTINY, bar,
                    Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, h - 32, Graphics.FONT_XTINY,
                    "elapsed " + fmtMs(_c.elapsedMs()), Graphics.TEXT_JUSTIFY_CENTER);
    }
}

class SetDelegate extends WatchUi.InputDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        InputDelegate.initialize();
        _c = c;
    }

    function onSelect() as Boolean {
        if (_c.isFinished()) {
            _c.finishWorkout();
            return true;
        }
        _c.completeSet();
        return true;
    }

    function onNextPage() as Boolean {
        _c.adjustWeight(5);
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        _c.adjustWeight(-5);
        WatchUi.requestUpdate();
        return true;
    }
}
