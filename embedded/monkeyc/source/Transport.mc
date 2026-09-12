// Liftosaur — transport seam for watch -> phone frames.
// Owner: Embedded Agent.
//
// Phase 2 needs a decision (docs/00 §4): BLE GATT peripheral (option A) vs
// Toybox.Communications.transmit over the phone (option B). Rather than bake
// that in, the controller talks to a LiftTransport; swapping the whole
// transport is one line in RecordingController.initialize().
//
// LiftLogTransport is the default: it writes the contract frame to the device
// console, which makes the whole pipeline observable on the watch today (and in
// `monkeydo`/simulator logs) with no BLE permission and no phone.

import Toybox.Lang;
import Toybox.System;

class LiftTransport {

    // Deliver one contract frame. Base class is a no-op.
    function emit(frame as Dictionary) as Void {
    }

    // Human-readable name for the UI/debug.
    function name() as String {
        return "null";
    }
}

// Default transport: log the frame. Used for HW checkpoint 2 validation.
class LiftLogTransport extends LiftTransport {

    private var _frames;

    function initialize() {
        LiftTransport.initialize();
        _frames = 0;
    }

    function emit(frame as Dictionary) as Void {
        _frames++;
        System.println(LiftFrame.toLogLine(frame) + " frames=" + _frames);
    }

    function name() as String {
        return "log";
    }

    function frames() as Number {
        return _frames;
    }
}

// Phase 2 placeholder — BLE peripheral (docs/00 §4 option A). Not yet wired:
// requires the BluetoothLowEnergy permission in manifest.xml and a GATT service
// definition, and the phone-side central in mobile/flutter.
//
// class LiftBleTransport extends LiftTransport { ... }
