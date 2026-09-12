import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/protocol.dart';

void main() {
  group('LiftFrame decoding (docs/01 §7)', () {
    test('decodes a chunk frame and scales samples to m/s²', () {
      final f = LiftFrame.fromWire({
        'v': 1,
        'type': 'chunk',
        'seq': 412,
        'ts': 1724865600123,
        'exercise_id': 3,
        'rate_hz': 20,
        'flags': 0,
        'sample_count': 2,
        'channels': ['x', 'y', 'z'],
        'scale': 1000,
        'samples': [
          [-120, 980, -44],
          [0, 1010, -60],
        ],
      });

      expect(f.type, FrameType.chunk);
      expect(f.seq, 412);
      expect(f.rateHz, 20);
      expect(f.sampleCount, 2);
      expect(f.scale, 1000);
      expect(f.toMs2(980), closeTo(0.98, 1e-9));
      expect(f.toMs2(-120), closeTo(-0.12, 1e-9));
      expect(f.validate(), isEmpty);
      expect(f.isChunkEnd, isFalse);
    });

    test('sample spacing follows the declared rate, not an assumed 100 Hz', () {
      final f = LiftFrame.fromWire({'type': 'chunk', 'seq': 1, 'rate_hz': 25});
      expect(f.samplePeriod.inMicroseconds, 40000); // 25 Hz => 40 ms
      // doc 01 §4: sample k occurs at timestamp_ms + k*1000/rate_hz
      expect(
        f.sampleTime(2).millisecondsSinceEpoch -
            f.sampleTime(0).millisecondsSinceEpoch,
        80,
      );
    });

    test('decodes set_end with the CHUNK_END flag', () {
      final f = LiftFrame.fromWire({
        'v': 1,
        'type': 'set_end',
        'seq': 413,
        'ts': 1724865618123,
        'flags': flagChunkEnd, // docs/01 §5: the watch must set bit0 on SET_END
        'duration_ms': 18000,
        'rep_hint': 0,
      });
      expect(f.type, FrameType.setEnd);
      expect(f.durationMs, 18000);
      expect(f.isChunkEnd, isTrue);
    });

    test('rejects an unknown frame type', () {
      expect(
        () => LiftFrame.fromWire({'type': 'nonsense'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('validate() reports structural problems instead of throwing', () {
      final bad = LiftFrame.fromWire({
        'type': 'chunk',
        'seq': -1,
        'rate_hz': 0,
        'scale': 0,
        'samples': [
          [1, 2, 3],
        ],
      });
      final problems = bad.validate();
      expect(problems, isNotEmpty);
      expect(problems.join(' '), contains('rate_hz'));
      expect(problems.join(' '), contains('scale'));
    });
  });
}
