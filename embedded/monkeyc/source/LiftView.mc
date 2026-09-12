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

        // Link diagnostics. Previously a "sent=0 / fail=0" screen was a dead end
        // because nothing distinguished "not connected" from "connected but the
        // characteristic was never found". Show the reason and the skip count.
        var skipped = _controller.getSkipped();
        var fails = _controller.getWriteFails();
        var trouble = fails > 0 || skipped > 0;
        dc.setColor(trouble ? Graphics.COLOR_ORANGE : Graphics.COLOR_DK_GRAY,
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 + 58, Graphics.FONT_XTINY,
                    "ble:" + _controller.getTxStatus() +
                    " adv=" + _controller.getAdvertisersSeen() +
                    " snt=" + _controller.getFramesSent(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 + 74, Graphics.FONT_XTINY,
                    "skip=" + skipped + " fail=" + fails,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var drops = _controller.getDropped();
        dc.setColor(drops > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_DK_GRAY,
                    Graphics.COLOR_TRANSPARENT);
        dc.drawText(w/2, h/2 + 90, Graphics.FONT_XTINY,
                    "buf_drop=" + drops + " pend=" + _controller.getPending(),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
