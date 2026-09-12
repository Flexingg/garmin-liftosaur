import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/frame_source.dart';
import 'package:liftosaur_garmin/protocol.dart';
import 'package:liftosaur_garmin/set_session.dart';

LiftFrame chunk(int seq, {int rateHz = 20, int samples = 20, int ts = 1000000}) =>
    LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.chunk,
      seq: seq,
      timestampMs: ts,
      exerciseId: 1,
      rateHz: rateHz,
      flags: 0,
      scale: 1000,
      channels: const ['x', 'y', 'z'],
      samples: [for (var i = 0; i < samples; i++) [i, 9810, -i]],
    );

LiftFrame setEnd(int seq, {int durationMs = 12000, int ts = 1012000}) => LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.setEnd,
      seq: seq,
      timestampMs: ts,
      exerciseId: 1,
      rateHz: 20,
      flags: flagChunkEnd,
      scale: 1000,
      channels: const ['x', 'y', 'z'],
      samples: const [],
      durationMs: durationMs,
      repHint: 0,
    );

SetSession newSession() => SetSession(
      userId: 'jonathan',
      exerciseId: 1,
      exerciseName: 'Squat',
      prescribedWeightLbs: 225,
    );

void main() {
  group('SetSession assembly (docs/01 -> docs/02)', () {
    test('assembles chunks into a valid backend payload', () {
      final s = newSession();
      expect(s.addFrame(LiftFrame.fromWire({
        'type': 'hello',
        'seq': 0,
        'rate_hz': 20,
        'scale': 1000,
        'channels': ['x', 'y', 'z'],
      })), IngestResult.accepted);

      for (var i = 1; i <= 3; i++) {
        expect(s.addFrame(chunk(i)), IngestResult.accepted);
      }
      expect(s.addFrame(setEnd(4)), IngestResult.accepted);

      expect(s.isReady, isTrue, reason: s.blockers().join(', '));
      expect(s.chunkCount, 3);
      expect(s.sampleCount, 60);
      expect(s.gapCount, 0);
      expect(s.capturedSeconds, closeTo(3.0, 1e-9));

      final payload = s.toBackendPayload();
      // docs/02 §1 required fields
      for (final key in [
        'user_id',
        'exercise_id',
        'exercise_name',
        'prescribed_weight_lbs',
        'started_at',
        'ended_at',
        'sample_rate_hz',
        'channel_mask',
        'scale',
        'samples',
      ]) {
        expect(payload.containsKey(key), isTrue, reason: 'missing $key');
      }
      expect(payload['samples'], hasLength(60));
      expect(payload['sample_rate_hz'], 20);
      expect(payload['channel_mask'], 7);
      expect(payload['scale'], 1000);
      expect(payload['seq_start'], 1);
      expect(payload['seq_end'], 3);
      // ISO8601 wall-clock bounds
      expect(DateTime.parse(payload['started_at']).isUtc, isTrue);
      expect(
        DateTime.parse(payload['ended_at'])
            .isAfter(DateTime.parse(payload['started_at'])),
        isTrue,
      );
      // every row must be [x,y,z] or the backend 422s
      for (final row in payload['samples'] as List) {
        expect(row, hasLength(3));
      }
    });

    test('detects and counts a seq gap (dropped frames, docs/01 §8)', () {
      final s = newSession();
      s.addFrame(chunk(1));
      final r = s.addFrame(chunk(5)); // 2..4 lost
      expect(r, IngestResult.gap);
      expect(s.gapCount, 1);
      expect(s.warnings.any((w) => w.contains('seq gap')), isTrue);
    });

    test('ignores duplicate / out-of-order frames', () {
      final s = newSession();
      s.addFrame(chunk(1));
      expect(s.addFrame(chunk(1)), IngestResult.duplicate);
      expect(s.duplicateSeq, 1);
      expect(s.sampleCount, 20, reason: 'duplicate must not append samples');
    });

    test('refuses frames after SET_END', () {
      final s = newSession();
      s.addFrame(chunk(1));
      s.addFrame(setEnd(2));
      expect(s.ended, isTrue);
      expect(s.addFrame(chunk(3)), IngestResult.afterEnd);
    });

    test('blocks upload until there are enough samples (backend needs >=4)', () {
      final s = newSession();
      expect(s.blockers(), contains('no samples captured'));
      s.addFrame(chunk(1, samples: 2));
      expect(s.blockers().join(' '), contains('need >=4 samples'));
      s.addFrame(chunk(2, samples: 4));
      expect(s.isReady, isTrue);
    });

    test('toBackendPayload throws rather than sending an invalid set', () {
      expect(() => newSession().toBackendPayload(), throwsStateError);
    });

    test('a malformed chunk is counted, not fatal', () {
      final s = newSession();
      s.addFrame(chunk(1));
      final bad = LiftFrame.fromWire({'type': 'chunk', 'seq': 2, 'rate_hz': 0});
      expect(s.addFrame(bad), IngestResult.rejected);
      expect(s.warnings, isNotEmpty);
      expect(s.gapCount, 0, reason: 'a rejected frame must not advance _lastSeq');
      expect(s.addFrame(chunk(2)), IngestResult.accepted);
    });
  });

  group('SyntheticFrameSource', () {
    test('replays a complete, gap-free, uploadable set', () async {
      final src = SyntheticFrameSource(rateHz: 20, seconds: 6);
      final s = newSession();
      final done = src.frames.listen(s.addFrame).asFuture<void>();
      await src.start();
      await src.stop();
      await done;

      expect(s.ended, isTrue, reason: 'SET_END should have arrived');
      expect(s.rateHz, 20);
      expect(s.sampleCount, 120); // 20 Hz * 6 s
      expect(s.gapCount, 0);
      expect(s.isReady, isTrue, reason: s.blockers().join(', '));

      // Gravity-dominant on Z: the mean |z| should look like ~9.81 m/s².
      final zs = s.samples.map((r) => r[2] / 1000.0).toList();
      final meanZ = zs.reduce((a, b) => a + b) / zs.length;
      expect(meanZ, greaterThan(7.0));
      expect(meanZ, lessThan(12.5));
    });
  });
}
