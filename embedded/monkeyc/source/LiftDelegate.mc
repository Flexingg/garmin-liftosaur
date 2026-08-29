// Liftosaur — input delegate. Hardware Start/Stop toggles recording.
// Owner: Embedded Agent.

using Toybox.WatchUi as Ui;

class LiftDelegate extends Ui.BehaviorDelegate {

    hidden var _controller;

    function initialize(controller as RecordingController) {
        BehaviorDelegate.initialize();
        _controller = controller;
    }

    // Venu 2: the Start/Stop physical button fires onSelect.
    function onSelect() {
        _controller.onToggle();
        return true;
    }
}
