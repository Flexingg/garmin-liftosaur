// Liftosaur — watch UI. Renders the active state and live capture stats.
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
    // exercise/weight string here in STATE_IDLE, from CMD frames.)
    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var state = _controller.getState();

        var title = "";
        var tint = Graphics.COLOR_WHITE;
        switch (state) {
            case STATE_INIT:      title = "LIFTOSAUR"; break;
            case STATE_IDLE:      title = "IDLE";      break;
            case STATE_RECORDING: title = "RECORDING"; tint = Graphics.COLOR_RED; break;
            case STATE_STOPPED:   title = "STOPPED";   break;
        }

        dc.setColor(tint, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 - 60, Graphics.FONT_MEDIUM, title,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 - 10, Graphics.FONT_SMALL,
                    _controller.getRateHz().format("%.1f") + " Hz  n=" +
                    _controller.getSampleCount(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.drawText(w/2, h/2 + 30, Graphics.FONT_SMALL,
                    "chunks=" + _controller.getChunksSent() +
                    " pend=" + _controller.getPending(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var drops = _controller.getDropped();
        dc.setColor(drops > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_DK_GRAY,
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 + 65, Graphics.FONT_XTINY,
                    "tx=" + _controller.getTransportName() + " drops=" + drops,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
