// Liftosaur — watch UI. Renders the active state and live sensor stats.
// Owner: Embedded Agent.

import Toybox.Lang;
import Toybox.Graphics;
import Toybox.WatchUi;

class LiftView extends WatchUi.View {

    private var _controller;

    function initialize(controller as RecordingController) {
        View.initialize();
        _controller = controller;
    }

    function onShow() {
    }

    // Redraw for the current state. (Phase 3 will add the prescribed
    // exercise/weight string here in STATE_IDLE.)
    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var state = _controller.getState();
        var title = "";
        switch (state) {
            case STATE_INIT:     title = "LIFTOSAUR";  break;
            case STATE_IDLE:     title = "IDLE";       break;
            case STATE_RECORDING:title = "RECORDING";  break;
            case STATE_STOPPED:  title = "STOPPED";    break;
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth()/2, dc.getHeight()/2 - 30,
                    Graphics.FONT_MEDIUM, title,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var info = "rate=" + _controller.getRateHz().format("%.1f") +
                   "Hz  n=" + _controller.getSampleCount();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth()/2, dc.getHeight()/2 + 40,
                    Graphics.FONT_SMALL, info,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
