// Liftosaur watch workout — views and input.
//
// Two screens:
//   DayPickerView  choose which program day to train
//   SetView        the workout itself: exercise, target weight x reps, rest clock
//
// TWO HARD-WON LAYOUT/INPUT RULES, both learned from a broken first version:
//
//  1. Handlers MUST live on a WatchUi.BehaviorDelegate. onSelect/onNextPage/
//     onPreviousPage are declared by BehaviorDelegate, NOT InputDelegate. Put
//     them on an InputDelegate and everything COMPILES and nothing ever fires -
//     the app appears frozen.
//
//  2. The Venu 2S is a ROUND 360x360 display, so the corners of the square are
//     cut off by the bezel. Nothing is placed near the edges: content is stacked
//     around the centre, where the circle is widest, and the long lines sit near
//     the middle. safeHalfWidth() gives the usable half-width at a given y.
//
// Input (Venu 2S has only SELECT + BACK plus a touchscreen):
//   SELECT (top-right) / tap   complete the set, or start the workout
//   swipe up / down            change day, or adjust the current set's weight
//   BACK (bottom-right)        leave; the save/discard prompt handles the activity

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Usable half-width of the display at vertical offset dy from the centre. On a
// round screen this shrinks to zero at top and bottom, which is why nothing is
// drawn within ~30px of the edges.
function safeHalfWidth(dc as Graphics.Dc, y as Number) as Number {
    var w = dc.getWidth();
    var h = dc.getHeight();
    var r = (w < h ? w : h) / 2;
    var dy = y - (h / 2);
    if (dy < 0) { dy = -dy; }
    if (dy >= r) { return 0; }
    return Math.sqrt((r * r) - (dy * dy)).toNumber();
}

// Draw centred text, shrinking to a smaller font if it would run into the bezel.
function drawCentered(dc as Graphics.Dc, y as Number, text as String,
                      font as Graphics.FontType, color as Number) as Void {
    var usable = safeHalfWidth(dc, y);
    var size = font;
    // Rough per-character widths; good enough to decide when to step down a size.
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

class DayPickerView extends WatchUi.View {

    private var _c;

    function initialize(c as WorkoutController) {
        View.initialize();
        _c = c;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var h = dc.getHeight();
        var c0 = h / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        drawCentered(dc, c0 - 116, "LIFTOSAUR", Graphics.FONT_XTINY,
                     Graphics.COLOR_LT_GRAY);

        var n = _c.dayCount();
        drawCentered(dc, c0 - 74, "Day " + (_c.selectedDay() + 1) + " of " + n,
                     Graphics.FONT_MEDIUM, Graphics.COLOR_WHITE);

        // day names can be long ("Day 6 - Weekend Beast Mode"): wrap on a space
        var name = _c.dayName(_c.selectedDay());
        var cut = name.find(" - ");
        if (name.length() > 16 && cut != null) {
            drawCentered(dc, c0 - 22, name.substring(0, cut), Graphics.FONT_SMALL,
                         Graphics.COLOR_WHITE);
            drawCentered(dc, c0 + 4, name.substring(cut + 3, name.length()),
                         Graphics.FONT_SMALL, Graphics.COLOR_WHITE);
        } else {
            drawCentered(dc, c0 - 10, name, Graphics.FONT_SMALL, Graphics.COLOR_WHITE);
        }

        drawCentered(dc, c0 + 50,
                     _c.dayExerciseCount(_c.selectedDay()) + " exercises",
                     Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);
        drawCentered(dc, c0 + 70,
                     _c.daySetCount(_c.selectedDay()) + " sets",
                     Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);

        drawCentered(dc, c0 + 108, "swipe = day    \u25b6 = start",
                     Graphics.FONT_XTINY, Graphics.COLOR_DK_GRAY);
    }
}

class DayPickerDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
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
        return (t / 60).format("%d") + ":" + (t % 60).format("%02d");
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var h = dc.getHeight();
        var c0 = h / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // Rest takes over the screen: it is what the user is waiting on.
        if (_c.isResting()) {
            drawCentered(dc, c0 - 104, "REST", Graphics.FONT_XTINY,
                         Graphics.COLOR_LT_GRAY);
            drawCentered(dc, c0 - 34, _c.restRemaining().format("%d"),
                         Graphics.FONT_NUMBER_MEDIUM, Graphics.COLOR_WHITE);
            drawCentered(dc, c0 + 34, "of " + _c.restTotal() + "s",
                         Graphics.FONT_SMALL, Graphics.COLOR_LT_GRAY);
            drawCentered(dc, c0 + 76, _c.currentExerciseName(), Graphics.FONT_XTINY,
                         Graphics.COLOR_WHITE);
            drawCentered(dc, c0 + 96,
                         "set " + _c.currentSetNumber() + " of " +
                         _c.currentExerciseSetCount(),
                         Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);
            drawCentered(dc, c0 + 126, "\u25b6 next set", Graphics.FONT_XTINY,
                         Graphics.COLOR_DK_GRAY);
            return;
        }

        if (_c.isFinished()) {
            drawCentered(dc, c0 - 60, "DONE", Graphics.FONT_MEDIUM,
                         Graphics.COLOR_WHITE);
            drawCentered(dc, c0 - 4, _c.setsDone() + " of " + _c.setsTotal(),
                         Graphics.FONT_MEDIUM, Graphics.COLOR_WHITE);
            drawCentered(dc, c0 + 44, "sets logged", Graphics.FONT_XTINY,
                         Graphics.COLOR_LT_GRAY);
            drawCentered(dc, c0 + 76, "elapsed " + fmtMs(_c.elapsedMs()),
                         Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);
            drawCentered(dc, c0 + 118, "\u25b6 finish & save", Graphics.FONT_XTINY,
                         Graphics.COLOR_DK_GRAY);
            return;
        }

        // header: which day, how far in
        drawCentered(dc, c0 - 118, _c.dayName(_c.selectedDay()), Graphics.FONT_XTINY,
                     Graphics.COLOR_LT_GRAY);
        drawCentered(dc, c0 - 98,
                     _c.setsDone() + " of " + _c.setsTotal() + " sets",
                     Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);

        // exercise name, wrapped on a space so it never runs off the bezel
        var name = _c.currentExerciseName();
        var cut = name.find(",");
        if (cut == null) { cut = name.find(" "); }
        if (name.length() > 16 && cut != null) {
            drawCentered(dc, c0 - 72, name.substring(0, cut), Graphics.FONT_SMALL,
                         Graphics.COLOR_WHITE);
            drawCentered(dc, c0 - 46, name.substring(cut + 1, name.length()),
                         Graphics.FONT_SMALL, Graphics.COLOR_WHITE);
        } else {
            drawCentered(dc, c0 - 62, name, Graphics.FONT_SMALL,
                         Graphics.COLOR_WHITE);
        }

        // the target, biggest thing on screen and dead centre
        drawCentered(dc, c0 - 4, _c.currentWeight().format("%d") + " lb",
                     Graphics.FONT_NUMBER_MEDIUM, Graphics.COLOR_WHITE);
        drawCentered(dc, c0 + 44,
                     "x " + _c.currentReps().format("%d") +
                     (_c.currentAmrap() ? "+" : ""),
                     Graphics.FONT_MEDIUM, Graphics.COLOR_WHITE);

        drawCentered(dc, c0 + 82,
                     "set " + _c.currentSetNumber() + " of " +
                     _c.currentExerciseSetCount() + "   rest " + _c.currentRest() + "s",
                     Graphics.FONT_XTINY, Graphics.COLOR_LT_GRAY);

        // footer: what the buttons do, and how long we have been at it
        if (_c.isCurrentLogged()) {
            drawCentered(dc, c0 + 112, "logged \u2013 \u25b6 for next",
                         Graphics.FONT_XTINY, Graphics.COLOR_DK_GRAY);
        } else {
            drawCentered(dc, c0 + 112, "swipe = weight", Graphics.FONT_XTINY,
                         Graphics.COLOR_DK_GRAY);
        }
        drawCentered(dc, c0 + 134, fmtMs(_c.elapsedMs()), Graphics.FONT_XTINY,
                     Graphics.COLOR_DK_GRAY);
    }
}

class SetDelegate extends WatchUi.BehaviorDelegate {

    private var _c;

    function initialize(c as WorkoutController) {
        BehaviorDelegate.initialize();
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
