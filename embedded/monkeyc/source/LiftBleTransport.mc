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
//
// ---------------------------------------------------------------------------
// TWO BUGS FIXED AFTER THE FIRST HARDWARE RUN (watch showed `ble:lost` + skips):
//
//  1. NO SCAN FILTER. It paired with *whatever advertiser appeared first* —
//     any BLE device in range. Pairing with an unrelated device yields exactly
//     "paired but never usable", and explains a stray 6-digit passkey prompt.
//     Now it only pairs when the advertisement contains our service UUID or
//     carries our local name.
//  2. NO WATCHDOG. `pairDevice()` returning a device stopped scanning and then
//     nothing connected, so the transport sat in `lost` forever while every
//     frame was skipped. `tick()` now recovers: an unconnected pair attempt is
//     abandoned (and unpaired) after PAIR_TIMEOUT_MS, and scanning resumes.
//
// STATUS: compiles, wired into the app, and the diagnostics are verified to
// report truthfully on hardware. Successful streaming is still unproven — that
// is Hardware Checkpoint 2.

import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;

// UUIDs of the PHONE's GATT server. Mirrored in the Dart client
// (mobile/flutter/lib/ble_link.dart) and documented in docs/04-ble-transport.md.
module LiftBle {
    // Advertised local name, used as a secondary scan filter.
    const LOCAL_NAME = "Liftosaur";

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

    // Give up on a pair attempt that never connects, then scan again.
    private const PAIR_TIMEOUT_MS = 8000;
    // If we are connected but can never resolve the characteristic, the peer is
    // probably wrong (or its GATT server is not serving our profile): re-scan.
    private const MAX_RESOLVE_TRIES = 40;

    private var _delegate;
    private var _device;         // from onConnectedStateChanged
    private var _pairedDevice;   // from pairDevice()
    private var _service;
    private var _data;           // the characteristic we write to
    private var _scanning;
    private var _connected;
    private var _encrypted;
    private var _started;
    private var _framesSent;
    private var _fragmentsSent;
    private var _writeFails;
    private var _skipped;        // frames dropped because the link was not ready
    private var _resolveTries;
    private var _pairStartedMs;  // System.getTimer() at the last pairDevice
    private var _lastStatus;
    private var _sawAdvertisers;

    function initialize() {
        LiftTransport.initialize();
        _device = null;
        _pairedDevice = null;
        _service = null;
        _data = null;
        _scanning = false;
        _connected = false;
        _encrypted = false;
        _started = false;
        _framesSent = 0;
        _fragmentsSent = 0;
        _writeFails = 0;
        _skipped = 0;
        _resolveTries = 0;
        _pairStartedMs = 0;
        _lastStatus = 0;
        _sawAdvertisers = 0;
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

        _started = true;
        resumeScanning();
        System.println("LiftBle: scanning for '" + LiftBle.LOCAL_NAME + "'");
    }

    function stop() as Void {
        if (!(Toybox has :BluetoothLowEnergy)) { return; }
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        _scanning = false;
    }

    function name() as String {
        return "ble:" + statusLine();
    }

    function framesSent() as Number { return _framesSent; }
    function writeFails() as Number { return _writeFails; }
    function skipped() as Number { return _skipped; }
    function fragmentsSent() as Number { return _fragmentsSent; }
    function isConnected() as Boolean { return _connected; }
    function isEncrypted() as Boolean { return _encrypted; }
    function lastWriteStatus() as Number { return _lastStatus; }
    function advertisersSeen() as Number { return _sawAdvertisers; }
    function deviceName() as String {
        return _device == null ? "" : _device.getName();
    }

    // Compact on-screen state so the watch itself explains the link:
    //   off | scan | waiting | no-svc | no-char | ready
    function statusLine() as String {
        if (!_started) { return "off"; }
        if (_connected) {
            if (_service == null) { return "no-svc"; }
            if (_data == null) { return "no-char"; }
            return "ready";
        }
        if (_pairStartedMs != 0) { return "waiting"; }  // paired, awaiting connect
        if (_scanning) { return "scan"; }
        return "lost";
    }

    // ------------------------------------------------------------ link upkeep

    private function resumeScanning() as Void {
        _scanning = true;
        _pairStartedMs = 0;
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
    }

    // Called periodically by the controller (see LiftTransport.tick). Without
    // this, a pair attempt that never connected left the transport in `lost`
    // forever, skipping every frame.
    function tick() as Void {
        if (!_started || _connected) { return; }

        // Abandon a stalled pair attempt so the watch is not wedged on a device
        // that will never connect.
        if (_pairStartedMs != 0) {
            if ((System.getTimer() - _pairStartedMs) > PAIR_TIMEOUT_MS) {
                System.println("LiftBle: pair timed out; unpairing and rescanning");
                if (_pairedDevice != null) {
                    BluetoothLowEnergy.unpairDevice(_pairedDevice);
                    _pairedDevice = null;
                }
                _resolveTries = 0;
                resumeScanning();
            }
            return;
        }

        // Connected but unusable for too long: the peer is not serving our
        // profile. Drop it and look again rather than skipping every frame.
        if (_resolveTries > MAX_RESOLVE_TRIES) {
            System.println("LiftBle: characteristic never resolved; rescanning");
            if (_device != null) {
                BluetoothLowEnergy.unpairDevice(_device);
            }
            _device = null;
            _connected = false;
            _service = null;
            _data = null;
            _resolveTries = 0;
            resumeScanning();
            return;
        }

        if (!_scanning) { resumeScanning(); }
    }

    // ---------------------------------------------------------------- transport

    function emit(frame as Dictionary) as Void {
        if (!(Toybox has :BluetoothLowEnergy)) { return; }
        if (_data == null && _connected) {
            // Retry resolution: getService()/getCharacteristic() can return null
            // if GATT discovery had not finished when onConnectedStateChanged
            // fired. Retrying here recovers without a reconnect.
            resolveCharacteristic();
        }
        if (_data == null) {
            // Still nothing to write to. COUNT it - a silent return here is what
            // made "sent=0, fail=0" impossible to diagnose on the watch.
            _skipped++;
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

    // Look up our service + characteristic on the connected device. Safe to call
    // repeatedly: it is retried from emit() while the link is not ready, because
    // GATT discovery may not have completed when the connect callback fired.
    function resolveCharacteristic() as Void {
        _resolveTries++;
        if (_device == null) { return; }
        if (_service == null) {
            _service = _device.getService(LiftBle.serviceUuid());
        }
        if (_service != null && _data == null) {
            _data = _service.getCharacteristic(LiftBle.dataUuid());
        }
    }

    // Only the phone running our GATT server is a valid peer. Matching on the
    // service UUID is the real test; the local name is a lenient fallback for
    // platforms that do not put the service UUID in the advertisement.
    function isOurPeripheral(sr as BluetoothLowEnergy.ScanResult) as Boolean {
        var name = sr.getDeviceName();
        if (name != null && name.equals(LiftBle.LOCAL_NAME)) { return true; }

        var uuids = sr.getServiceUuids();
        var u = uuids.next();
        while (u != null) {
            var uuid = u as BluetoothLowEnergy.Uuid;
            if (uuid != null && uuid.equals(LiftBle.serviceUuid())) { return true; }
            u = uuids.next();
        }
        return false;
    }

    function handleScanResults(results as BluetoothLowEnergy.Iterator) as Void {
        if (_connected || _pairStartedMs != 0) { return; }  // already working on it

        var r = results.next();
        while (r != null) {
            var sr = r as BluetoothLowEnergy.ScanResult;
            if (sr == null) { r = results.next(); continue; }

            _sawAdvertisers++;
            if (!isOurPeripheral(sr)) {
                // NOT ours - keep scanning. Pairing with a random advertiser was
                // the original bug.
                r = results.next();
                continue;
            }

            System.println("LiftBle: found our peripheral '" +
                           (sr.getDeviceName() == null ? "?" : sr.getDeviceName()) +
                           "' rssi=" + sr.getRssi());

            // Stop scanning only once we have found the right device.
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
            _scanning = false;

            var dev = BluetoothLowEnergy.pairDevice(sr);
            if (dev == null) {
                System.println("LiftBle: pairDevice returned null; rescanning");
                resumeScanning();
            } else {
                _pairedDevice = dev;
                _pairStartedMs = System.getTimer();
                System.println("LiftBle: paired; waiting for connection");
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
            _pairedDevice = device;
            _connected = true;
            _pairStartedMs = 0;
            _resolveTries = 0;
            resolveCharacteristic();
            System.println("LiftBle: connected; service=" +
                           (_service == null ? "NOT FOUND" : "ok") +
                           " characteristic=" +
                           (_data == null ? "NOT FOUND" : "ok"));
        } else {
            _connected = false;
            _device = null;
            _service = null;
            _data = null;
            _resolveTries = 0;
            System.println("LiftBle: disconnected (state=" + state + ")");
            // Drop back to scanning so a re-paired phone reconnects next set.
            resumeScanning();
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
