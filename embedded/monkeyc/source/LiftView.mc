// Liftosaur — watch UI. Renders the active state and live sensor stats.
// Owner: Embedded Agent.

using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Lang as Lang;

class LiftView extends Ui.View {

    hidden var _controller;

    function initialize(controller as RecordingController) {
        View.initialize();
        _controller = controller;
    }

    function onShow() {
    }

    // Redraw for the current state. (Phase 3 will add the prescribed
    // exercise/weight string here in STATE_IDLE.)
    function onUpdate(dc as Dc) {
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();

        var state = _controller.getState();
        var title = "";
        switch (state) {
            case LiftState.STATE_INIT:     title = "LIFTOSAUR";  break;
            case LiftState.STATE_IDLE:     title = "IDLE";       break;
            case LiftState.STATE_RECORDING:title = "RECORDING";  break;
            case LiftState.STATE_STOPPED:  title = "STOPPED";    break;
        }

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth()/2, dc.getHeight()/2 - 30,
                    Gfx.FONT_MEDIUM, title,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);

        var info = "rate=" + _controller.getRateHz().format("%.1f") +
                   "Hz  n=" + _controller.getSampleCount();
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth()/2, dc.getHeight()/2 + 40,
                    Gfx.FONT_SMALL, info,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
    }
}
