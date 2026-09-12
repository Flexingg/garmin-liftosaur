// Liftosaur — BLE transport (watch = CENTRAL, phone = PERIPHERAL).
//
// !! ROLE INVERSION — read this before changing anything !!
// Garmin's Connect IQ BLE API is CENTRAL ROLE ONLY: the module docs say so, and
// every BleDelegate callback is central-side (onScanResults, notifications
// *received from* a peripheral). There are no advertising or GATT-server APIs,
// so a Connect IQ app CANNOT be a BLE peripheral. "True real-time BLE" is
// therefore achieved by inverting the roles:
//
//     phone (Flutter, flutter_ble_peripheral)  = PERIPHERAL, hosts the GATT
//                                                server, advertises our service
//     watch (this file)                        = CENTRAL, scans for it, pairs,
//                                                and WRITES chunk frames to the
//                                                phone's RX characteristic
//
// Sequence: setDelegate -> registerProfile -> setScanState(SCANNING) ->
//   onScanResults -> pairDevice(scanResult) -> onConnectedStateChanged ->
//   device.getService() -> service.getCharacteristic() -> requestWrite(...)
//
// Data path: frame (dictionary, from LiftFrame) -> LiftBinary.encode ->
//   fragment to maxPayload chunks -> requestWrite per fragment.
// No response is required per fragment (WRITE_TYPE_DEFAULT) so streaming is not
// throttled by round trips; fragments are ordered and the phone reassembles.
//
// STATUS: compiles and is wired into the app, but end-to-end BLE behaviour has
// NOT been verified on hardware yet (that needs the phone app installed and
// both devices in range). Treat the pairing UX and the fragment size as tuning
// knobs to confirm with Hardware Checkpoint 2.

import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;

// UUIDs of the PHONE's GATT server. Mirrored in the Dart client
// (mobile/flutter/lib/ble_link.dart) and documented in docs/04-ble-transport.md.
module LiftBle {
    function serviceUuid() as BluetoothLowEnergy.Uuid {
        return BluetoothLowEnergy.stringToUuid("4c494654-0001-4000-8000-00805f9b34fb");
    }
    // Watch -> phone (chunks). The phone receives these as writes to its RX char.
    function dataUuid() as BluetoothLowEnergy.Uuid {
        return BluetoothLowEnergy.stringToUuid("4c494654-0002-4000-8000-00805f9b34fb");
    }
}

class LiftBleDelegate extends BluetoothLowEnergy.BleDelegate {

    private var _owner;

    function initialize(owner as LiftBleTransport) {
        BluetoothLowEnergy.BleDelegate.initialize();
        _owner = owner;
    }

    function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        _owner.handleScanResults(scanResults);
    }

    function onScanStateChange(scanState as BluetoothLowEnergy.ScanState,
                              status as BluetoothLowEnergy.Status) as Void {
        _owner.handleScanState(scanState, status);
    }

    function onConnectedStateChanged(device as BluetoothLowEnergy.Device,
                                     state as BluetoothLowEnergy.ConnectionState) as Void {
        _owner.handleConnection(device, state);
    }

    function onCharacteristicWrite(characteristic as BluetoothLowEnergy.Characteristic,
                                   status as BluetoothLowEnergy.Status) as Void {
        _owner.handleWrite(characteristic, status);
    }

    function onEncryptionStatus(device as BluetoothLowEnergy.Device,
                                status as BluetoothLowEnergy.Status) as Void {
        _owner.handleEncryption(device, status);
    }
}

class LiftBleTransport extends LiftTransport {

    // Fragment payload size. Must satisfy: 4 + payload <= (MTU - 3). 180 leaves
    // room for an MTU of ~187+, which both Android and the watch negotiate in
    // practice; if writes start failing, lower this before anything else.
    private const MAX_FRAGMENT_PAYLOAD = 180;

    private var _delegate;
    private var _device;
    private var _service;
    private var _data;          // the characteristic we write to
    private var _scanning;
    private var _connected;
    private var _encrypted;
    private var _framesSent;
    private var _fragmentsSent;
    private var _writeFails;
    private var _lastStatus;

    function initialize() {
        LiftTransport.initialize();
        _device = null;
        _service = null;
        _data = null;
        _scanning = false;
        _connected = false;
        _encrypted = false;
        _framesSent = 0;
        _fragmentsSent = 0;
        _writeFails = 0;
        _lastStatus = 0;
    }

    // Register the profile the phone will host, then start scanning for it.
    //
    // NOTE: do NOT call BluetoothLowEnergy.setConnectionStrategy() here. It is
    // in the SDK 9.2.0 API but is NOT present on the Venu 2S runtime (firmware
    // 19.05 / CIQ 6.0.2), and Monkey C does not reject it at build time - it
    // throws at runtime, on app start:
    //     Error: Symbol Not Found Error
    //     Details: "Could not find symbol 'setConnectionStrategy'"
    // The default strategy applies anyway (non-secure, no bonding prompt). If
    // bonding is ever needed, feature-detect before use - see
    // tools/check-device-api.py, which now guards this whole class of bug.
    function start() as Void {
        if (!(Toybox has :BluetoothLowEnergy)) {
            System.println("LiftBle: no BluetoothLowEnergy on this device");
            return;
        }
        _delegate = new LiftBleDelegate(self);
        BluetoothLowEnergy.setDelegate(_delegate);

        BluetoothLowEnergy.registerProfile({
            :uuid => LiftBle.serviceUuid(),
            :characteristics => [{
                :uuid => LiftBle.dataUuid(),
                :descriptors => [BluetoothLowEnergy.cccdUuid()]
            }]
        });

        _scanning = true;
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
        System.println("LiftBle: scanning for the phone's GATT server");
    }

    function stop() as Void {
        if (!(Toybox has :BluetoothLowEnergy)) { return; }
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        _scanning = false;
    }

    function name() as String {
        if (_connected) {
            if (_data != null) { return "ble"; }
            return "ble:svc?";      // connected but characteristic not resolved
        }
        if (_scanning) { return "ble:scan"; }
        return "ble:idle";
    }

    function framesSent() as Number { return _framesSent; }
    function writeFails() as Number { return _writeFails; }
    function isConnected() as Boolean { return _connected; }
    function isEncrypted() as Boolean { return _encrypted; }
    function lastWriteStatus() as Number { return _lastStatus; }
    function deviceName() as String {
        return _device == null ? "" : _device.getName();
    }

    // ---------------------------------------------------------------- transport

    function emit(frame as Dictionary) as Void {
        if (!(Toybox has :BluetoothLowEnergy)) { return; }
        if (_data == null) {
            // Not connected yet: nothing to do but report it. The caller keeps
            // buffering (SampleBuffer counts drops), so a late connection still
            // streams rather than silently losing the set.
            _lastStatus = -1;
            return;
        }

        var bytes = LiftBinary.encode(frame);
        var parts = LiftBinary.fragment(bytes, MAX_FRAGMENT_PAYLOAD);
        for (var i = 0; i < parts.size(); i++) {
            // WRITE_TYPE_DEFAULT per docs/01: streaming must not wait on a
            // response round-trip per fragment.
            _data.requestWrite(parts[i], {
                :writeType => BluetoothLowEnergy.WRITE_TYPE_DEFAULT
            });
            _fragmentsSent++;
        }
        _framesSent++;
    }

    // ---------------------------------------------------------------- callbacks

    function handleScanResults(results as BluetoothLowEnergy.Iterator) as Void {
        var r = results.next();
        while (r != null) {
            // Iterator.next() is typed Object; narrow it before using it.
            var sr = r as BluetoothLowEnergy.ScanResult;
            if (sr == null) { r = results.next(); continue; }
            var name = sr.getDeviceName();
            System.println("LiftBle: saw '" + (name == null ? "?" : name) +
                           "' rssi=" + sr.getRssi());
            // Pair with the first advertiser of our service. A stronger filter
            // (name match) belongs here once the phone app is named-for-real;
            // getServiceUuids() is available on the ScanResult for that.
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
            _scanning = false;
            var dev = BluetoothLowEnergy.pairDevice(sr);
            if (dev == null) {
                System.println("LiftBle: pairDevice returned null; rescanning");
                _scanning = true;
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            } else {
                System.println("LiftBle: paired with the phone");
            }
            return;
        }
    }

    function handleScanState(scanState as BluetoothLowEnergy.ScanState,
                             status as BluetoothLowEnergy.Status) as Void {
        System.println("LiftBle: scanState=" + scanState + " status=" + status);
    }

    function handleConnection(device as BluetoothLowEnergy.Device,
                              state as BluetoothLowEnergy.ConnectionState) as Void {
        if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _device = device;
            _connected = true;
            _service = device.getService(LiftBle.serviceUuid());
            if (_service != null) {
                _data = _service.getCharacteristic(LiftBle.dataUuid());
            }
            System.println("LiftBle: connected; characteristic=" +
                           (_data == null ? "NOT FOUND" : "ok"));
        } else {
            _connected = false;
            _device = null;
            _service = null;
            _data = null;
            System.println("LiftBle: disconnected (state=" + state + ")");
            // Drop back to scanning so a re-paired phone reconnects next set.
            if (!_scanning) {
                _scanning = true;
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            }
        }
    }

    function handleWrite(characteristic as BluetoothLowEnergy.Characteristic,
                         status as BluetoothLowEnergy.Status) as Void {
        _lastStatus = status;
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            _writeFails++;
            System.println("LiftBle: write failed status=" + status +
                           " fails=" + _writeFails);
        }
    }

    function handleEncryption(device as BluetoothLowEnergy.Device,
                              status as BluetoothLowEnergy.Status) as Void {
        _encrypted = (status == BluetoothLowEnergy.STATUS_SUCCESS);
        System.println("LiftBle: encryption status=" + status);
    }
}
