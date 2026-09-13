// Liftosaur watch workout — views and input.
//
// Design brief: Apple-Watch-like restraint, in Liftosaur's purple. Each screen
// shows ONE thing prominently and almost nothing else. The first version was a
// wall of small grey lines, which read as crowded on a 360px round display.
//
// LAYOUT RULES (learned the hard way):
//  - The Venu 2S is a ROUND 360x360: the square's corners are behind the bezel.
//    Everything is centred, with a progress ring at r=150 and no text near the
//    edges. safeHalfWidth() gives the usable width at a given y.
//  - Handlers MUST be on a WatchUi.BehaviorDelegate. onSelect/onNextPage/
//    onPreviousPage belong to BehaviorDelegate; on an InputDelegate they are
//    never called and the app looks frozen.
//  - This device has no up/down buttons and no long-press: SELECT, BACK and
//    swipes are the whole vocabulary. So swipes adjust values, SELECT confirms.
//
// Screens: ProgramPicker -> DayPicker -> SetView (with a rest mode and an AMRAP
// "how many reps?" mode) -> finish.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Liftosaur palette. Purple carries emphasis; everything secondary is grey so
// the one number that matters stands out.
const LIFT_PURPLE = 0x9B6EF3;
const LIFT_PURPLE_BRIGHT = 0xC9B4FF;
const LIFT_PURPLE_DIM = 0x4A3D73;
const LIFT_TEXT = 0xFFFFFF;
const LIFT_TEXT_DIM = 0x9A9AA2;

// Usable half-width of the display at vertical offset dy from the centre.
function safeHalfWidth(dc as Graphics.Dc, y as Number) as Number {
    var w = dc.getWidth();
    var h = dc.getHeight();
    var r = (w < h ? w : h) / 2;
    var dy = y - (h / 2);
    if (dy < 0) { dy = -dy; }
    if (dy >= r) { return 0; }
    return Math.sqrt((r * r) - (dy * dy)).toNumber();
}

// Centred text, shrinking a size when it would run into the bezel.
function drawCentered(dc as Graphics.Dc, y as Number, text as String,
                      font as Graphics.FontType, color as Number) as Void {
    var usable = safeHalfWidth(dc, y);
    var size = font;
    var perChar = size == Graphics.FONT_NUMBER_MEDIUM ? 26
                : size == Graphics.FONT_NUMBER_HOT ? 34
                : size == Graphics.FONT_MEDIUM ? 14
                : size == Graphics.FONT_SMALL ? 11 : 8;
    if (text.length() * perChar > usable * 2) {
        if (size == Graphics.FONT_NUMBER_MEDIUM) { size = Graphics.FONT_MEDIUM; }
        else if (size == Graphics.FONT_MEDIUM) { size = Graphics.FONT_SMALL; }
        else if (size == Graphics.FONT_SMALL) { size = Graphics.FONT_XTINY; }
    }
    dc.setColor(color, Graphics.COLOR_TRANSPARENT);
    dc.drawText(dc.getWidth() / 2, y, size, text, Graphics.TEXT_JUSTIFY_CENTER);
}

// A ring of dots around the edge - the Apple-Watch progress gesture, drawn with
// primitives that certainly exist (drawArc's argument order varies by SDK).
// progress 0.0..1.0 fills clockwise from the top.
function drawProgressRing(dc as Graphics.Dc, progress as Float,
                          filled as Number, empty as Number) as Void {
    var cx = dc.getWidth() / 2;
    var cy = dc.getHeight() / 2;
    var r = 150;
    var segs = 28;
    for (var i = 0; i < segs; i++) {
        var frac = i.toFloat() / segs;
        var ang = (frac * 2.0 * Math.PI) - (Math.PI / 2.0);
        var x = (cx + (Math.cos(ang) * r)).toNumber();
        var y = (cy + (Math.sin(ang) * r)).toNumber();
        dc.setColor(frac <= progress ? filled : empty, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, 3);
    }
}

// ---------------------------------------------------------------- list picker

// Shared by the program picker and the day picker: a title, one focal item and
// a swipe hint. mode picks which list it reads.
class ListPickerView extends WatchUi.View {

    private var _c;
    private var _mode;   // "program" | "day"

    function initialize(c as WorkoutController, mode as String) {
        View.initialize();
        _c = c;
        _mode = mode;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var n = _mode.equals("program") ? _c.programCount() : _c.dayCount();
        var idx = _mode.equals("program") ? _c.selectedProgramIndex()
                                          : _c.selectedDay();
        if (n == 0) {
            // Nothing loaded yet: say so rather than showing an empty screen.
            drawCentered(dc, c0 - 30, "NO PLAN", Graphics.FONT_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 16, "check the backend", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            return;
        }

        drawCentered(dc, c0 - 118, _mode.equals("program") ? "PROGRAM" : "DAY",
                     Graphics.FONT_XTINY, LIFT_PURPLE);
        drawCentered(dc, c0 - 96, (idx + 1) + " of " + n, Graphics.FONT_XTINY,
                     LIFT_TEXT_DIM);

        if (_mode.equals("program")) {
            var name = _c.programLabel(idx);
            drawCentered(dc, c0 - 14, name, Graphics.FONT_SMALL, LIFT_TEXT);
            drawCentered(dc, c0 + 34, "swipe to change", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
        } else {
            drawCentered(dc, c0 - 52, _c.dayName(idx), Graphics.FONT_MEDIUM,
                         LIFT_TEXT);
            drawCentered(dc, c0 + 2, _c.daySectionLabel(idx), Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 + 46,
                         _c.dayExerciseCount(idx) + " exercises \\u00b7 " +
                         _c.daySetCount(idx) + " sets",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
        }

        drawCentered(dc, c0 + 108, "swipe   \\u25b6 " +
                     (_mode.equals("program") ? "choose" : "start"),
                     Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
    }
}

class ListPickerDelegate extends WatchUi.BehaviorDelegate {

    private var _c;
    private var _mode;

    function initialize(c as WorkoutController, mode as String) {
        BehaviorDelegate.initialize();
        _c = c;
        _mode = mode;
    }

    function onNextPage() as Boolean {
        if (_mode.equals("program")) {
            var n = _c.programCount();
            if (n > 0) { _c.selectProgramIndex((_c.selectedProgramIndex() + 1) % n); }
        } else {
            var m = _c.dayCount();
            if (m > 0) { _c.selectDay((_c.selectedDay() + 1) % m); }
        }
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        if (_mode.equals("program")) {
            var n = _c.programCount();
            if (n > 0) {
                _c.selectProgramIndex((_c.selectedProgramIndex() + n - 1) % n);
            }
        } else {
            var m = _c.dayCount();
            if (m > 0) { _c.selectDay((_c.selectedDay() + m - 1) % m); }
        }
        WatchUi.requestUpdate();
        return true;
    }

    function onSelect() as Boolean {
        if (_mode.equals("program")) {
            _c.chooseSelectedProgram();
            _c.reloadPlan();          // pull the newly chosen program's plan
            WatchUi.pushView(new ListPickerView(_c, "day"),
                             new ListPickerDelegate(_c, "day"),
                             WatchUi.SLIDE_LEFT);
            return true;
        }
        _c.startWorkout();
        WatchUi.pushView(new SetView(_c), new SetDelegate(_c), WatchUi.SLIDE_LEFT);
        return true;
    }
}

// ------------------------------------------------------------------ set view

class SetView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    // Filled ring = progress through the session's sets.
    private function progress() as Float {
        var total = _c.setsTotal();
        if (total <= 0) { return 0.0; }
        return _c.setsDone().toFloat() / total.toFloat();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // ---- rest: the only thing that matters is the clock
        if (_c.isResting()) {
            var left = _c.restRemaining().toFloat();
            var total = _c.restTotal();
            var frac = (total > 0) ? (left / total.toFloat()) : 0.0;
            drawProgressRing(dc, frac, LIFT_PURPLE_BRIGHT, LIFT_PURPLE_DIM);
            drawCentered(dc, c0 - 96, "REST", Graphics.FONT_XTINY, LIFT_PURPLE);
            drawCentered(dc, c0 - 22, _c.restRemaining().format("%d"),
                         Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 34, "of " + total + "s", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            drawCentered(dc, c0 + 104, "\\u25b6 skip rest", Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            return;
        }

        // ---- AMRAP: ask how many reps were actually completed
        if (_c.isAwaitingReps()) {
            drawProgressRing(dc, progress(), LIFT_PURPLE, LIFT_PURPLE_DIM);
            drawCentered(dc, c0 - 96, "REPS DONE", Graphics.FONT_XTINY, LIFT_PURPLE);
            drawCentered(dc, c0 - 20, _c.currentReps().format("%d"),
                         Graphics.FONT_NUMBER_MEDIUM, LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 + 36, "target " + _c.currentReps() + "+",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            drawCentered(dc, c0 + 104, "swipe   \\u25b6 log set",
                         Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
            return;
        }

        // ---- session complete
        if (_c.isFinished()) {
            drawProgressRing(dc, 1.0, LIFT_PURPLE_BRIGHT, LIFT_PURPLE_DIM);
            drawCentered(dc, c0 - 46, "DONE", Graphics.FONT_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 2, _c.setsDone() + " of " + _c.setsTotal() + " sets",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            drawCentered(dc, c0 + 104, "\\u25b6 finish & save", Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            return;
        }

        // ---- the working screen: exercise, weight, reps. Nothing else.
        drawProgressRing(dc, progress(), LIFT_PURPLE, LIFT_PURPLE_DIM);
        drawCentered(dc, c0 - 62, _c.currentExerciseName(), Graphics.FONT_SMALL,
                     LIFT_TEXT_DIM);
        drawCentered(dc, c0 - 8, _c.currentWeight().format("%d"),
                     Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
        drawCentered(dc, c0 + 40,
                     "lb \\u00d7 " + _c.currentReps().format("%d") +
                     (_c.currentAmrap() ? "+" : ""),
                     Graphics.FONT_MEDIUM, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 + 112, "swipe = weight   \\u25b6 = done",
                     Graphics.FONT_XTINY, LIFT_PURPLE_DIM);
    }
}

class SetDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
        _c = c;
    }

    function onSelect() as Boolean {
        // Order matters: resting must NOT fall through to logging a set.
        if (_c.isResting()) { _c.skipRest(); return true; }
        if (_c.isAwaitingReps()) { _c.confirmReps(); return true; }
        if (_c.isFinished()) { _c.finishWorkout(); return true; }
        _c.completeSet();
        return true;
    }

    function onNextPage() as Boolean {
        // During rest, swipe adds time; otherwise it adjusts the value on screen.
        if (_c.isResting()) { _c.startRest(_c.restRemaining() + 15); }
        else if (_c.isAwaitingReps()) { _c.adjustReps(1); }
        else { _c.adjustWeight(5); }
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        if (_c.isResting()) { _c.startRest(_c.restRemaining() - 15); }
        else if (_c.isAwaitingReps()) { _c.adjustReps(-1); }
        else { _c.adjustWeight(-5); }
        WatchUi.requestUpdate();
        return true;
    }
}
