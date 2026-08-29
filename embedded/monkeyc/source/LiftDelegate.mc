// Liftosaur — input delegate. Hardware Start/Stop toggles recording.
// Owner: Embedded Agent.

import Toybox.Lang;
import Toybox.WatchUi;

class LiftDelegate extends WatchUi.BehaviorDelegate {

    private var _controller;

    function initialize(controller as RecordingController) {
        BehaviorDelegate.initialize();
        _controller = controller;
    }

    // Venu 2: the Start/Stop physical button fires onSelect.
    function onSelect() as Boolean {
        _controller.onToggle();
        return true;
    }
}
