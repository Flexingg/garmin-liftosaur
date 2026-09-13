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
                drawCentered(dc, c0 + 14, _c.activityNote(), Graphics.FONT_XTINY,
                             LIFT_PURPLE_BRIGHT);
            }
            if (!_c.syncNote().equals("")) {
                drawCentered(dc, c0 + 34, _c.syncNote(), Graphics.FONT_XTINY,
                             LIFT_TEXT_DIM);
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

    // Controls, as specified by the user:
    //   top button      -> next set
    //   bottom button    -> edit the current set (weight/reps)
    //   tap              -> exercise info
    //   hold bottom      -> options
    //   hold top         -> end workout
    //   (swipes still move between sets, which costs nothing and helps)

    function onSelect() as Boolean {
        // The top button. NOTE: on a touch device a screen tap may also arrive
        // here if onTap is not delivered to a BehaviorDelegate - in that case a
        // tap behaves as "next" rather than "info".
        if (_c.isResting()) { _c.skipRest(); return true; }
        if (_c.isFinished()) { _c.finishWorkout(); return true; }
        _c.advance();
        return true;
    }

    // A real tap, when the framework delivers it, is "info".
    function onTap(event as WatchUi.ClickEvent) as Boolean {
        if (_c.isResting()) { _c.skipRest(); return true; }
        WatchUi.pushView(new ExerciseInfoView(_c), new InfoDelegate(_c),
                         WatchUi.SLIDE_LEFT);
        return true;
    }

    // Bottom button: edit this set.
    function onBack() as Boolean {
        if (_c.isResting()) { _c.skipRest(); return true; }
        WatchUi.pushView(new AdjustView(_c), new AdjustDelegate(_c), WatchUi.SLIDE_LEFT);
        return true;
    }

    // Hold bottom: options.
    function onMenu() as Boolean {
        var menu = new WatchUi.Menu2({ :title => "Workout" });
        menu.addItem(new WatchUi.MenuItem("View workout", null, "list", null));
        menu.addItem(new WatchUi.MenuItem("Exercise info", null, "info", null));
        menu.addItem(new WatchUi.MenuItem("Skip to next exercise", null, "skipex", null));
        menu.addItem(new WatchUi.MenuItem("End workout", null, "finish", null));
        WatchUi.pushView(menu, new SetMenuDelegate(_c), WatchUi.SLIDE_UP);
        return true;
    }

    // Hold top: end the workout.
    function onNextMode() as Boolean {
        _c.finishWorkout();
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
            WatchUi.pushView(buildSetList(_c), new SetListDelegate(_c),
                             WatchUi.SLIDE_UP);
        } else if (id.equals("info")) {
            WatchUi.pushView(new ExerciseInfoView(_c), new InfoDelegate(_c),
                             WatchUi.SLIDE_LEFT);
        } else if (id.equals("skipex")) {
            _c.skipExercise();
        } else if (id.equals("finish")) {
            _c.finishWorkout();
        }
    }
}

// ------------------------------------------------------------------ edit set

// Bottom button opens this. Swipes adjust the FOCUSED field; tap switches
// between weight and reps - there is no other gesture left on this device.
class AdjustView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var c0 = dc.getHeight() / 2;
        var isWeight = _c.adjustFieldIsWeight();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        drawRing(dc, _c.setProgress(), LIFT_PURPLE_TRACK, LIFT_PURPLE);
        drawCentered(dc, c0 - 108, "EDIT SET", Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 - 52, _c.currentWeight().format("%d") + " lb",
                     Graphics.FONT_NUMBER_MEDIUM,
                     isWeight ? LIFT_TEXT : LIFT_TEXT_DIM);
        drawCentered(dc, c0 + 4, _c.currentReps().format("%d") + " reps",
                     Graphics.FONT_MEDIUM,
                     isWeight ? LIFT_TEXT_DIM : LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 + 52, isWeight ? "swiping: weight" : "swiping: reps",
                     Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
        drawCentered(dc, c0 + 108, "tap = switch   back = done",
                     Graphics.FONT_XTINY, LIFT_TEXT_DIM);
    }
}

class AdjustDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
        _c = c;
    }

    function onNextPage() as Boolean {
        if (_c.adjustFieldIsWeight()) { _c.adjustWeight(5); } else { _c.adjustReps(1); }
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        if (_c.adjustFieldIsWeight()) { _c.adjustWeight(-5); } else { _c.adjustReps(-1); }
        WatchUi.requestUpdate();
        return true;
    }

    function onSelect() as Boolean {
        _c.toggleAdjustField();
        WatchUi.requestUpdate();
        return true;
    }

    function onTap(event as WatchUi.ClickEvent) as Boolean {
        _c.toggleAdjustField();
        WatchUi.requestUpdate();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

// ---------------------------------------------------------------- set list

// Opens the full list of SETS (not exercises) for the day. Built as a plain
// Menu2 and pushed once from the options menu.
//
// The previous version was a View whose delegate re-opened the list on EVERY
// input (select, menu and back all called openList()), so the user could not
// get out of it - it just cycled. Back now pops.
function buildSetList(c as WorkoutController) as WatchUi.Menu2 {
    var menu = new WatchUi.Menu2({ :title => c.dayName(c.selectedDay()) });
    var n = c.setCount();
    for (var i = 0; i < n; i++) {
        menu.addItem(new WatchUi.MenuItem(c.setLabelAt(i), c.setSublabelAt(i),
                                          i.toString(), null));
    }
    return menu;
}

class SetListDelegate extends WatchUi.Menu2InputDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        Menu2InputDelegate.initialize();
        _c = c;
    }

    // Tap a set -> jump straight to it, and close the list.
    function onSelect(item as WatchUi.MenuItem) as Void {
        var raw = item.getId();
        var idx = (raw as String).toNumber();
        if (idx != null) {
            _c.jumpToSet(idx);
        }
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    // Back out of the list (this is what was broken).
    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
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

        // Stacked vertically, biggest facts first. A rolling stack (rather than
        // scattered labels) is what makes this readable on a round screen.
        var y = c0 - 118;
        drawCentered(dc, y, _c.currentExerciseName(), Graphics.FONT_SMALL, LIFT_TEXT);
        y += 26;
        drawCentered(dc, y, "target " + _c.targetText(), Graphics.FONT_XTINY,
                     LIFT_PURPLE_BRIGHT);
        y += 24;

        if (!_c.infoLoaded()) {
            drawCentered(dc, y + 10, "loading last time...", Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
        } else {
            drawCentered(dc, y, "LAST TIME  " + _c.infoDateText(),
                         Graphics.FONT_XTINY, LIFT_TEXT_DIM);
            y += 24;
            var lines = _c.infoSetLines();
            for (var i = 0; i < lines.size() and i < 3; i++) {
                drawCentered(dc, y, lines[i] as String, Graphics.FONT_SMALL, LIFT_TEXT);
                y += 26;
            }
            drawCentered(dc, y, _c.infoTopText() + "   " + _c.infoE1rmText(),
                         Graphics.FONT_XTINY, LIFT_PURPLE_BRIGHT);
            y += 22;
            drawCentered(dc, y, _c.infoVolumeText(), Graphics.FONT_XTINY,
                         LIFT_TEXT_DIM);
        }
        drawCentered(dc, c0 + 140, "back = return", Graphics.FONT_XTINY,
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
