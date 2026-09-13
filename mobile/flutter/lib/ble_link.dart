/// BLE link: the PHONE is the peripheral, the watch is the central.
///
/// Role inversion is forced by Garmin: the Connect IQ BLE API is central-role
/// only (no advertising, no GATT server), so a watch app cannot be a peripheral.
/// Instead this app hosts the GATT server and the watch connects and writes
/// chunk frames to our RX characteristic. See docs/04-ble-transport.md.
///
/// The UUIDs below are the contract with the watch — they are mirrored in
/// `embedded/monkeyc/source/LiftBleTransport.mc` and must stay in sync.
library;

import 'dart:async';
import 'dart:typed_data';


import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import 'binary_frames.dart';
import 'frame_source.dart';
import 'protocol.dart';

/// Service the watch scans for (must equal LiftBle.serviceUuid()).
const String kLiftServiceUuid = '4c494654-0001-4000-8000-00805f9b34fb';

/// Characteristic the watch WRITES chunk fragments to. On the phone this is the
/// RX characteristic, which is what `onDataReceived` reports.
const String kLiftDataUuid = '4c494654-0002-4000-8000-00805f9b34fb';

/// Advertised name; used to recognise the phone during the watch's scan.
const String kLiftLocalName = 'Liftosaur';

/// Turns a stream of BLE fragments into whole, decoded frames.
///
/// Pure Dart and plugin-free on purpose: this is the part that can be wrong in
/// ways that silently corrupt a workout, so it is unit-tested.
class FrameAssembler {
  final FrameReassembler reassembler;

  FrameAssembler({FrameReassembler? reassembler})
      : reassembler = reassembler ?? FrameReassembler();

  int fragmentsReceived = 0;
  int framesDecoded = 0;
  int decodeErrors = 0;
  int versionMismatches = 0;
  final List<String> lastErrors = [];

  /// Feed one fragment. Returns a frame when one completes, else null.
  LiftFrame? add(Uint8List fragment) {
    fragmentsReceived++;
    final Uint8List? whole = reassembler.add(fragment);
    if (whole == null) return null;
    try {
      final f = decodeFrame(whole);
      framesDecoded++;
      return f;
    } on FormatException catch (e) {
      // A corrupt frame must not kill the set: count it and carry on.
      decodeErrors++;
      if (e.message.contains('protocol version')) versionMismatches++;
      if (lastErrors.length < 5) lastErrors.add(e.message);
      return null;
    }
  }

  String summary() =>
      'frags=$fragmentsReceived frames=$framesDecoded '
      'decodeErr=$decodeErrors dupFrag=${reassembler.duplicateFragments} '
      'partialDrops=${reassembler.incompleteDrops}';
}

/// A [FrameSource] backed by this device acting as a BLE peripheral.
class BlePeripheralFrameSource implements FrameSource {
  final FlutterBlePeripheral _peripheral;
  final FrameAssembler assembler;

  final _controller = StreamController<LiftFrame>.broadcast();

  /// Human-readable link events for the app's debug log. The watch cannot show
  /// us anything (its `System.println` never reaches CIQ_LOG.YML), so anything
  /// this side observes belongs in front of the user.
  final StreamController<String> _events = StreamController<String>.broadcast();

  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<int>? _mtuSub;
  StreamSubscription<dynamic>? _writeSub;
  StreamSubscription<bool>? _subStateSub;
  Timer? _poll;

  bool _running = false;
  PeripheralBluetoothState? lastState;
  int? negotiatedMtu;
  String? lastError;

  /// What the PLATFORM reports, polled - not what we assumed at start().
  /// Android silently stops advertising when the app is not in the foreground,
  /// so a one-shot flag set in start() can be a lie.
  bool advertisingNow = false;
  bool centralConnected = false;
  int centralConnects = 0;

  /// How many times the platform dropped our advertisement and we put it back.
  int advertisingRecoveries = 0;
  static const int _maxAdvertisingRecoveries = 5;

  /// Every GATT write the platform sees, whatever characteristic it targets.
  /// This is deliberately broader than [onDataReceived], which only reports the
  /// RX characteristic: if the watch writes and the bytes land on a different
  /// characteristic, `onDataReceived` stays silent while the data is right there.
  int gattWrites = 0;
  String? lastWriteCharacteristic;
  int lastWriteLength = 0;
  int subscriptionChanges = 0;
  bool centralSubscribed = false;

  BlePeripheralFrameSource({
    FlutterBlePeripheral? peripheral,
    FrameAssembler? assembler,
  })  : _peripheral = peripheral ?? FlutterBlePeripheral(),
        assembler = assembler ?? FrameAssembler();

  @override
  Stream<LiftFrame> get frames => _controller.stream;

  /// Link events (advertising on/off, central connect/disconnect, MTU, errors).
  Stream<String> get events => _events.stream;

  void _emitEvent(String msg) {
    if (!_events.isClosed) _events.add(msg);
  }

  @override
  bool get isRunning => _running;

  @override
  String get describe => 'BLE peripheral (watch connects to us)';

  /// Advertise + serve the GATT service the watch writes to.
  ///
  /// Returns false (with [lastError] set) rather than throwing when Bluetooth
  /// is off or unsupported, so the screen can show why nothing is arriving.
  @override
  Future<bool> start() async {
    if (_running) return true;
    try {
      // The MTU drives how many bytes the watch must put in one write; log it
      // because a small MTU is the usual cause of fragmentation surprises.
      _mtuSub = _peripheral.onMtuChanged.listen((int mtu) {
        negotiatedMtu = mtu;
        _emitEvent('MTU changed to $mtu (max write payload ${mtu - 3})');
      });
      _dataSub = _peripheral.onDataReceived.listen(_onFragment);

      // Anything the central writes, on ANY characteristic.
      _writeSub = _peripheral.onGattWrite.listen((w) {
        gattWrites++;
        final uuid = (w.characteristicUuid as String?) ?? '';
        final data = (w.data as Uint8List?) ?? Uint8List(0);
        lastWriteCharacteristic = uuid;
        lastWriteLength = data.length;
        final head = data.take(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        _emitEvent('GATT WRITE #$gattWrites char=$uuid len=${data.length} '
            'head=[$head]${uuid.toLowerCase() == kLiftDataUuid.toLowerCase() ? '' : '  <-- NOT our RX uuid'}');
        // Feed it to the assembler too: better to decode from a write we did not
        // nominally expect than to discard real data.
        if (data.isNotEmpty) _onFragment(data);
      });

      _subStateSub = _peripheral.onSubscriptionChanged.listen((bool subscribed) {
        subscriptionChanges++;
        centralSubscribed = subscribed;
        _emitEvent('subscription changed: $subscribed');
      });

      final state = await _peripheral.start(
        advertiseData: const AdvertiseDataCore(
          serviceUuid: kLiftServiceUuid,
          localName: kLiftLocalName,
        ),
        gattServer: const GattServerSettings(
          serviceUuid: kLiftServiceUuid,
          rxCharacteristicUuid: kLiftDataUuid,
        ),
      );
      lastState = state;
      // `granted`/`ready` both mean the advertisement is actually on air; every
      // other state (denied, turnedOff, unsupported, ...) means it is not.
      _running = state == PeripheralBluetoothState.granted ||
          state == PeripheralBluetoothState.ready;
      if (!_running) {
        lastError = 'peripheral state: ${state.name}';
        _emitEvent('start FAILED: $lastError');
      } else {
        _emitEvent('advertising service=$kLiftServiceUuid rx=$kLiftDataUuid '
            'name=$kLiftLocalName');
        _startPolling();
      }
      return _running;
    } catch (e) {
      // MissingPluginException on desktop/test, PlatformException on a device
      // that refuses advertising, etc.
      lastError = '$e';
      _running = false;
      _emitEvent('start threw: $e');
      return false;
    }
  }

  /// Poll what the platform actually thinks, and report every transition.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final adv = await _peripheral.isAdvertising;
        final central = await _peripheral.isConnected;
        if (adv != advertisingNow) {
          advertisingNow = adv;
          if (adv) {
            _emitEvent('advertising: TRUE (platform reports on air)');
          } else {
            _emitEvent('advertising: FALSE - the platform dropped it '
                '(Android stops advertising when the app is not in the '
                'foreground; screen off does it too)');
            // Put it back. Without this the app happily showed "ADVERTISING"
            // while nothing was on air, and the watch sat at adv=0 forever.
            if (_running && advertisingRecoveries < _maxAdvertisingRecoveries) {
              advertisingRecoveries++;
              _emitEvent('re-advertising (attempt $advertisingRecoveries/'
                  '$_maxAdvertisingRecoveries)');
              try {
                await _peripheral.start(
                  advertiseData: const AdvertiseDataCore(
                    serviceUuid: kLiftServiceUuid,
                    localName: kLiftLocalName,
                  ),
                  gattServer: const GattServerSettings(
                    serviceUuid: kLiftServiceUuid,
                    rxCharacteristicUuid: kLiftDataUuid,
                  ),
                );
                final again = await _peripheral.isAdvertising;
                advertisingNow = again;
                _emitEvent(again
                    ? 're-advertising: TRUE'
                    : 're-advertising FAILED - keep the app in the foreground');
              } catch (e) {
                _emitEvent('re-advertising threw: $e');
              }
            } else if (_running) {
              _emitEvent('advertising keeps dropping; not retrying further '
                  '(keep the app open, screen on)');
            }
          }
        }
        if (central != centralConnected) {
          centralConnected = central;
          if (central) centralConnects++;
          _emitEvent(central
              ? 'central CONNECTED (the watch is attached)'
              : 'central disconnected');
        }
      } catch (e) {
        _emitEvent('poll failed: $e');
      }
    });
  }

  void _onFragment(Uint8List bytes) {
    // First bytes ever received is worth shouting about: it means the watch's
    // writes are actually reaching us.
    if (assembler.fragmentsReceived == 1) {
      _emitEvent('first fragment received (${bytes.length} B) - watch writes land');
    }
    final frame = assembler.add(bytes);
    if (frame != null && !_controller.isClosed) _controller.add(frame);
  }

  @override
  Future<void> stop() async {
    _running = false;
    advertisingNow = false;
    _poll?.cancel();
    _poll = null;
    await _dataSub?.cancel();
    _dataSub = null;
    await _writeSub?.cancel();
    _writeSub = null;
    await _subStateSub?.cancel();
    _subStateSub = null;
    await _mtuSub?.cancel();
    _mtuSub = null;
    try {
      await _peripheral.stop();
    } catch (_) {
      // Nothing useful to do if the platform refuses to stop.
    }
    if (!_controller.isClosed) await _controller.close();
  }
}
