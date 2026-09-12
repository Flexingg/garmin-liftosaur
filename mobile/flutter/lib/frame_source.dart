/// Frame sources: where decoded watch frames come from.
///
/// The Phase 2 transport decision (docs/00 §4 — BLE GATT peripheral vs
/// `Toybox.Communications`) is still open, so the app depends on this
/// abstraction rather than on a concrete radio. That keeps the whole
/// capture -> assemble -> upload pipeline testable and demoable today:
/// [SyntheticFrameSource] replays a realistic set with no hardware at all.
library;

import 'dart:async';
import 'dart:math' as math;

import 'protocol.dart';

/// Something that yields watch frames.
abstract class FrameSource {
  Stream<LiftFrame> get frames;
  Future<void> start();
  Future<void> stop();
  bool get isRunning;
  String get describe;
}

/// Replays a plausible squat set: HELLO, ~1 s CHUNKs at [rateHz], then SET_END.
///
/// The signal is deliberately squat-shaped (gravity on Z with a slow
/// oscillation) so the backend's physics produces sanity-checkable numbers
/// rather than noise. Uses a fixed seed => deterministic, so it doubles as the
/// fixture for tests and for exercising the pipeline without a watch.
class SyntheticFrameSource implements FrameSource {
  final int rateHz;
  final double seconds;
  final int exerciseId;
  final int chunkIntervalMs;
  final bool realtime;

  final _controller = StreamController<LiftFrame>.broadcast();
  bool _running = false;
  int _seq = 1;

  SyntheticFrameSource({
    this.rateHz = 20,
    this.seconds = 12,
    this.exerciseId = 1,
    this.chunkIntervalMs = 1000,
    this.realtime = false,
  });

  @override
  Stream<LiftFrame> get frames => _controller.stream;

  @override
  bool get isRunning => _running;

  @override
  String get describe => 'synthetic ${rateHz}Hz x ${seconds}s';

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _seq = 1;

    final startedMs = DateTime.now().millisecondsSinceEpoch;
    const scale = 1000;

    _emit(LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.hello,
      seq: _seq++,
      timestampMs: startedMs,
      exerciseId: exerciseId,
      rateHz: rateHz,
      flags: 0,
      scale: scale,
      channels: const ['x', 'y', 'z'],
      samples: const [],
    ));

    final totalSamples = (rateHz * seconds).round();
    final samplesPerChunk = math.max(1, (rateHz * chunkIntervalMs / 1000).round());

    for (var base = 0; base < totalSamples; base += samplesPerChunk) {
      if (!_running) return;
      final rows = <List<int>>[];
      for (var k = 0; k < samplesPerChunk && base + k < totalSamples; k++) {
        final i = base + k;
        final t = i / rateHz;
        // ~0.4 Hz squat cadence; gravity dominant on Z, wrist sway on X/Y.
        final phase = 2 * math.pi * 0.4 * t;
        final z = 9.81 + 2.4 * math.sin(phase);
        final x = 0.45 * math.sin(phase + 0.6);
        final y = 0.30 * math.cos(phase);
        rows.add([
          (x * scale).round(),
          (y * scale).round(),
          (z * scale).round(),
        ]);
      }
      _emit(LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.chunk,
        seq: _seq++,
        timestampMs: startedMs + (base * 1000 ~/ rateHz),
        exerciseId: exerciseId,
        rateHz: rateHz,
        flags: 0,
        scale: scale,
        channels: const ['x', 'y', 'z'],
        samples: rows,
      ));
      if (realtime) await Future<void>.delayed(Duration(milliseconds: chunkIntervalMs));
    }

    if (!_running) return;
    _emit(LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.setEnd,
      seq: _seq++,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      exerciseId: exerciseId,
      rateHz: rateHz,
      flags: flagChunkEnd,
      scale: scale,
      channels: const ['x', 'y', 'z'],
      samples: const [],
      durationMs: (seconds * 1000).round(),
      repHint: 0,
    ));
  }

  void _emit(LiftFrame f) {
    if (!_controller.isClosed) _controller.add(f);
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _controller.close();
  }
}
