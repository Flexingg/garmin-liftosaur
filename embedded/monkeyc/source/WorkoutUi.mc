// Liftosaur watch workout — views and input.
//
// Apple-Watch-like restraint in Liftosaur's brand purple (#8356F6, taken from
// the app icon). One focal number per screen, a complete progress ring faded
// behind the text, and almost nothing else competing for attention.
//
// INPUT MAP (the user chose this explicitly; do not "improve" it):
//   swipe up / down    move to the previous / next SET
//   tap (or SELECT)    show info about the current EXERCISE
//   BACK (bottom)      log the set and advance
//   hold (menu)        options: view workout, adjust weight/reps, info, skip, finish
//   during rest        BACK / tap end the rest; swipe adds or removes 15s
//   AMRAP reps step    swipe adjusts the reps, BACK logs the set
//
// LAYOUT/INPUT RULES (each cost a hardware cycle):
//  - ROUND 360x360: the square's corners are behind the bezel. Everything is
//    centred, inside r=150, and long strings are shrunk by drawCentered().
//  - Handlers MUST be on WatchUi.BehaviorDelegate (onSelect/onNextPage/
//    onPreviousPage are declared there, not on InputDelegate).
//  - Monkey C does NOT process \\uXXXX escapes - use plain ASCII in strings.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Liftosaur brand purple, sampled from the app icon.
const LIFT_PURPLE = 0x8356F6;
const LIFT_PURPLE_BRIGHT = 0xA98BFF;
const LIFT_PURPLE_TRACK = 0x3A2C6E;
const LIFT_TEXT = 0xFFFFFF;
const LIFT_TEXT_DIM = 0x9A9AA2;

const RING_RADIUS = 150;
const RING_WIDTH = 9;

function safeHalfWidth(dc as Graphics.Dc, y as Number) as Number {
    var w = dc.getWidth();
    var h = dc.getHeight();
    var r = (w < h ? w : h) / 2;
    var dy = y - (h / 2);
    if (dy < 0) { dy = -dy; }
    if (dy >= r) { return 0; }
    return Math.sqrt((r * r) - (dy * dy)).toNumber();
}

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

// A COMPLETE ring: a faded track all the way round, with the progress arc drawn
// over it. Drawn before any text so it sits behind the numbers, not over them.
function drawRing(dc as Graphics.Dc, progress as Float,
                  trackColor as Number, arcColor as Number) as Void {
    var cx = dc.getWidth() / 2;
    var cy = dc.getHeight() / 2;
    dc.setPenWidth(RING_WIDTH);
    dc.setColor(trackColor, Graphics.COLOR_TRANSPARENT);
    dc.drawCircle(cx, cy, RING_RADIUS);

    if (progress > 0.0) {
        if (progress > 1.0) { progress = 1.0; }
        // drawCircle cannot do a partial arc, and drawArc's argument order varies
        // between SDK versions, so the arc is short line segments.
        var segs = 72;
        var upto = (progress * segs).toNumber();
        dc.setColor(arcColor, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < upto; i++) {
            var a0 = (i.toFloat() / segs) * 2.0 * Math.PI - (Math.PI / 2.0);
            var a1 = ((i + 1).toFloat() / segs) * 2.0 * Math.PI - (Math.PI / 2.0);
            dc.drawLine((cx + (Math.cos(a0) * RING_RADIUS)).toNumber(),
                        (cy + (Math.sin(a0) * RING_RADIUS)).toNumber(),
                        (cx + (Math.cos(a1) * RING_RADIUS)).toNumber(),
                        (cy + (Math.sin(a1) * RING_RADIUS)).toNumber());
        }
    }
    dc.setPenWidth(1);
}

// ------------------------------------------------------------------ list picker

// Program / day chooser. mode selects which list it reads.
class ListPickerView extends WatchUi.View {

    private var _c;
    private var _mode;

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
            drawCentered(dc, c0 - 30, "NO PLAN", Graphics.FONT_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 16, "check the backend", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            return;
        }

        var frac = (idx + 1).toFloat() / n.toFloat();
        drawRing(dc, frac, LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 118, _mode.equals("program") ? "PROGRAM" : "DAY",
                     Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 - 96, (idx + 1) + " of " + n, Graphics.FONT_XTINY,
                     LIFT_TEXT_DIM);

        if (_mode.equals("program")) {
            drawCentered(dc, c0 - 14, _c.programLabel(idx), Graphics.FONT_SMALL,
                         LIFT_TEXT);
        } else {
            drawCentered(dc, c0 - 52, _c.dayName(idx), Graphics.FONT_MEDIUM,
                         LIFT_TEXT);
            drawCentered(dc, c0 + 2, _c.daySectionLabel(idx), Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 + 46,
                         _c.dayExerciseCount(idx) + " exercises  " +
                         _c.daySetCount(idx) + " sets",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
        }
        drawCentered(dc, c0 + 96, "swipe   back = " +
                     (_mode.equals("program") ? "choose" : "start"),
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
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
            if (n > 0) { _c.selectProgramIndex((_c.selectedProgramIndex() + n - 1) % n); }
        } else {
            var m = _c.dayCount();
            if (m > 0) { _c.selectDay((_c.selectedDay() + m - 1) % m); }
        }
        WatchUi.requestUpdate();
        return true;
    }

    // BACK is the affirmative action on this device's layout.
    function onBack() as Boolean {
        return choose();
    }

    function onSelect() as Boolean {
        return choose();
    }

    private function choose() as Boolean {
        if (_mode.equals("program")) {
            _c.chooseSelectedProgram();
            _c.reloadPlan();
            WatchUi.pushView(new ListPickerView(_c, "day"),
                             new ListPickerDelegate(_c, "day"), WatchUi.SLIDE_LEFT);
            return true;
        }
        _c.startWorkout();
        WatchUi.pushView(new SetView(_c), new SetDelegate(_c), WatchUi.SLIDE_LEFT);
        return true;
    }
}

// ------------------------------------------------------------------- set view

class SetView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    private function progress() as Float {
        var total = _c.setsTotal();
        return total <= 0 ? 0.0 : _c.setsDone().toFloat() / total.toFloat();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // ---- rest
        if (_c.isResting()) {
            var total = _c.restTotal();
            var frac = total > 0 ? _c.restRemaining().toFloat() / total.toFloat() : 0.0;
            drawRing(dc, frac, LIFT_PURPLE_TRACK, LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 - 100, "REST", Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 - 24, _c.restRemaining().format("%d"),
                         Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 32, "of " + total + "s", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            drawCentered(dc, c0 + 92, "back = skip   swipe = +/-15s",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            return;
        }

        // ---- AMRAP: the reps actually completed drive 5/3/1 progression
        if (_c.isAwaitingReps()) {
            drawRing(dc, progress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
            drawCentered(dc, c0 - 100, "REPS DONE", Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 - 24, _c.currentReps().format("%d"),
                         Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 + 32, "swipe to change", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            drawCentered(dc, c0 + 92, "back = log set", Graphics.FONT_XTINY,
                         LIFT_PURPLE_BRIGHT);
            return;
        }

        // ---- done
        if (_c.isFinished()) {
            drawRing(dc, 1.0, LIFT_PURPLE_TRACK, LIFT_PURPLE_BRIGHT);
            drawCentered(dc, c0 - 56, "DONE", Graphics.FONT_MEDIUM, LIFT_TEXT);
            drawCentered(dc, c0 - 12, _c.setsDone() + " of " + _c.setsTotal() + " sets",
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            if (!_c.activityNote().equals("")) {
                drawCentered(dc, c0 + 16, _c.activityNote(), Graphics.FONT_XTINY,
                             LIFT_PURPLE_BRIGHT);
            }
            drawCentered(dc, c0 + 92, "hold = options", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
            return;
        }

        // ---- the working screen
        drawRing(dc, progress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 66, _c.currentExerciseName(), Graphics.FONT_SMALL,
                     LIFT_TEXT_DIM);
        drawCentered(dc, c0 - 12, _c.currentWeight().format("%d"),
                     Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
        drawCentered(dc, c0 + 36,
                     "lb x " + _c.currentReps().format("%d") +
                     (_c.currentAmrap() ? "+" : ""),
                     Graphics.FONT_MEDIUM, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 + 74,
                     "set " + _c.currentSetNumber() + " of " +
                     _c.currentExerciseSetCount(),
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
        drawCentered(dc, c0 + 112, "back = log   tap = info   swipe = set",
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
    }
}

class SetDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
        _c = c;
    }

    // BACK is the primary action: log the set and advance.
    function onBack() as Boolean {
        if (_c.isResting()) { _c.skipRest(); return true; }
        if (_c.isAwaitingReps()) { _c.confirmReps(); return true; }
        if (_c.isFinished()) { _c.finishWorkout(); return true; }
        _c.completeSet();
        return true;
    }

    // Tap (or the SELECT button) opens the exercise info screen.
    function onSelect() as Boolean {
        if (_c.isResting()) { _c.skipRest(); return true; }
        WatchUi.pushView(new ExerciseInfoView(_c), new InfoDelegate(_c),
                         WatchUi.SLIDE_LEFT);
        return true;
    }

    function onNextPage() as Boolean {
        if (_c.isResting()) { _c.startRest(_c.restRemaining() + 15); }
        else if (_c.isAwaitingReps()) { _c.adjustReps(1); }
        else { _c.stepForward(); }
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        if (_c.isResting()) { _c.startRest(_c.restRemaining() - 15); }
        else if (_c.isAwaitingReps()) { _c.adjustReps(-1); }
        else if (_c.canGoBack()) { _c.previousSet(); }
        WatchUi.requestUpdate();
        return true;
    }

    function onMenu() as Boolean {
        var menu = new WatchUi.Menu2({ :title => "Workout" });
        menu.addItem(new WatchUi.MenuItem("View workout", null, "list", null));
        menu.addItem(new WatchUi.MenuItem("Exercise info", null, "info", null));
        menu.addItem(new WatchUi.MenuItem("Adjust weight", null, "weight", null));
        menu.addItem(new WatchUi.MenuItem("Adjust reps", null, "reps", null));
        menu.addItem(new WatchUi.MenuItem("Skip to next exercise", null, "skipex", null));
        menu.addItem(new WatchUi.MenuItem("Finish & save", null, "finish", null));
        WatchUi.pushView(menu, new SetMenuDelegate(_c), WatchUi.SLIDE_UP);
        return true;
    }
}

class SetMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        Menu2InputDelegate.initialize();
        _c = c;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (id.equals("list")) {
            WatchUi.pushView(new ExerciseListView(_c), new ExerciseListDelegate(_c),
                             WatchUi.SLIDE_LEFT);
        } else if (id.equals("info")) {
            WatchUi.pushView(new ExerciseInfoView(_c), new InfoDelegate(_c),
                             WatchUi.SLIDE_LEFT);
        } else if (id.equals("weight")) {
            WatchUi.pushView(new AdjustView(_c, "weight"), new AdjustDelegate(_c, "weight"),
                             WatchUi.SLIDE_LEFT);
        } else if (id.equals("reps")) {
            WatchUi.pushView(new AdjustView(_c, "reps"), new AdjustDelegate(_c, "reps"),
                             WatchUi.SLIDE_LEFT);
        } else if (id.equals("skipex")) {
            _c.skipExercise();
        } else if (id.equals("finish")) {
            _c.finishWorkout();
        }
    }
}

// ------------------------------------------------------------------ adjust view

// Where weight and reps are edited now that swipes navigate sets.
class AdjustView extends WatchUi.View {

    private var _c;
    private var _mode;

    function initialize(c as WorkoutController, mode as String) {
        View.initialize();
        _c = c;
        _mode = mode;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        var isWeight = _mode.equals("weight");
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        drawRing(dc, _c.setProgress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 100, isWeight ? "WEIGHT" : "REPS",
                     Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 - 24,
                     (isWeight ? _c.currentWeight() : _c.currentReps()).format("%d"),
                     Graphics.FONT_NUMBER_MEDIUM, LIFT_TEXT);
        drawCentered(dc, c0 + 30, isWeight ? "lb" : "reps", Graphics.FONT_XTINY,
                     LIFT_TEXT_DIM);
        if (!isWeight) {
            drawCentered(dc, c0 + 52, "target " + _c.plannedReps() +
                         (_c.currentAmrap() ? "+" : ""),
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
        }
        drawCentered(dc, c0 + 96, "swipe = adjust   back = done",
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
    }
}

class AdjustDelegate extends WatchUi.BehaviorDelegate {

    private var _c;
    private var _mode;

    function initialize(c as WorkoutController, mode as String) {
        BehaviorDelegate.initialize();
        _c = c;
        _mode = mode;
    }

    function onNextPage() as Boolean {
        if (_mode.equals("weight")) { _c.adjustWeight(5); } else { _c.adjustReps(1); }
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        if (_mode.equals("weight")) { _c.adjustWeight(-5); } else { _c.adjustReps(-1); }
        WatchUi.requestUpdate();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

// ---------------------------------------------------------------- exercise list

class ExerciseListView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        drawRing(dc, _c.setProgress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 96, "WORKOUT", Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 - 40, _c.dayName(_c.selectedDay()), Graphics.FONT_SMALL,
                     LIFT_TEXT);
        drawCentered(dc, c0 + 4, _c.currentExercises().size() + " exercises",
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
        drawCentered(dc, c0 + 52, "hold = list", Graphics.FONT_XTINY, LIFT_TEXT_DIM);
    }
}

class ExerciseListDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
        _c = c;
    }

    // The list itself is a Menu2 (built on entry); opening it from any input
    // keeps this delegate trivially simple.
    private function openList() as Boolean {
        var menu = new WatchUi.Menu2({ :title => _c.dayName(_c.selectedDay()) });
        var n = _c.currentExercises().size();
        for (var i = 0; i < n; i++) {
            var sub = _c.exerciseIsDone(i) ? "done" : "";
            if (i == _c.currentExerciseIndex()) { sub = sub.equals("done") ? "done  now" : "now"; }
            menu.addItem(new WatchUi.MenuItem(_c.exerciseNameAt(i), sub, i.toString(), null));
        }
        WatchUi.pushView(menu, new ExerciseJumpDelegate(_c), WatchUi.SLIDE_UP);
        return true;
    }

    function onSelect() as Boolean { return openList(); }
    function onMenu() as Boolean { return openList(); }
    function onBack() as Boolean { return openList(); }
}

class ExerciseJumpDelegate extends WatchUi.Menu2InputDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        Menu2InputDelegate.initialize();
        _c = c;
    }

    // Tap an exercise -> jump to it.
    function onSelect(item as WatchUi.MenuItem) as Void {
        var raw = item.getId();
        var idx = (raw as String).toNumber();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (idx != null) {
            _c.jumpToExercise(idx);
        }
    }
}

// -------------------------------------------------------------------- info view

class ExerciseInfoView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
        _c.requestExerciseInfo();   // previous session comes from the backend
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        drawRing(dc, _c.setProgress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 104, _c.currentExerciseName(), Graphics.FONT_SMALL,
                     LIFT_TEXT);
        drawCentered(dc, c0 - 74, "today: " + _c.targetText(), Graphics.FONT_XTINY,
                     LIFT_PURPLE_BRIGHT);
        if (!_c.infoLoaded()) {
            drawCentered(dc, c0 - 6, "loading last time...", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
        } else {
            drawCentered(dc, c0 - 34, "LAST TIME " + _c.infoDateText(),
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            // the sets are the point of this screen: two short, centred lines
            var sets = _c.infoSetsText();
            var cut = sets.length() / 2;
            var sp = sets.find(" ");
            var second = "";
            while (sp != null and sp < cut) {
                var next = sets.find(" ", sp + 1);
                if (next == null) { break; }
                sp = next;
            }
            if (sets.length() > 26 and sp != null) {
                second = sets.substring(sp + 1, sets.length());
                sets = sets.substring(0, sp);
            }
            drawCentered(dc, c0 - 6, sets, Graphics.FONT_SMALL, LIFT_TEXT);
            if (!second.equals("")) {
                drawCentered(dc, c0 + 22, second, Graphics.FONT_SMALL, LIFT_TEXT);
            }
            drawCentered(dc, c0 + 56,
                         _c.infoTopText() + "   " + _c.infoE1rmText(),
                         Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        }
        drawCentered(dc, c0 + 112, "back = return", Graphics.FONT_XTINY,
                     LIFT_TEXT_DIM);
    }
}

class InfoDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
        _c = c;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    function onSelect() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    // swipe = move between sets, even from here
    function onNextPage() as Boolean {
        _c.stepForward(); WatchUi.popView(WatchUi.SLIDE_RIGHT); return true;
    }

    function onPreviousPage() as Boolean {
        if (_c.canGoBack()) { _c.previousSet(); }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
