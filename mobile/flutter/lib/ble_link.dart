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
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<int>? _mtuSub;

  bool _running = false;
  PeripheralBluetoothState? lastState;
  int? negotiatedMtu;
  String? lastError;

  BlePeripheralFrameSource({
    FlutterBlePeripheral? peripheral,
    FrameAssembler? assembler,
  })  : _peripheral = peripheral ?? FlutterBlePeripheral(),
        assembler = assembler ?? FrameAssembler();

  @override
  Stream<LiftFrame> get frames => _controller.stream;

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
      _mtuSub = _peripheral.onMtuChanged.listen((int mtu) => negotiatedMtu = mtu);
      _dataSub = _peripheral.onDataReceived.listen(_onFragment);

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
      if (!_running) lastError = 'peripheral state: ${state.name}';
      return _running;
    } catch (e) {
      // MissingPluginException on desktop/test, PlatformException on a device
      // that refuses advertising, etc.
      lastError = '$e';
      _running = false;
      return false;
    }
  }

  void _onFragment(Uint8List bytes) {
    final frame = assembler.add(bytes);
    if (frame != null && !_controller.isClosed) _controller.add(frame);
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _dataSub?.cancel();
    _dataSub = null;
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
