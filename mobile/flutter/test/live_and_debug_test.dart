import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/backend_client.dart';
import 'package:liftosaur_garmin/debug_log.dart';
import 'package:liftosaur_garmin/live_buffer.dart';
import 'package:liftosaur_garmin/protocol.dart';

LiftFrame chunk(int seq, {int samples = 20, int scale = 1000}) => LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.chunk,
      seq: seq,
      timestampMs: 1724865600123 + seq * 50,
      exerciseId: 1,
      rateHz: 20,
      flags: 0,
      scale: scale,
      channels: const ['x', 'y', 'z'],
      samples: [
        for (var i = 0; i < samples; i++) [0, 0, (9810 + i).round()],
      ],
    );

void main() {
  group('LiveBuffer', () {
    test('scales raw samples into m/s² and tracks stats', () {
      final b = LiveBuffer();
      b.addFrame(chunk(1, samples: 20, scale: 1000));
      expect(b.totalSamples, 20);
      expect(b.rateHz, 20);
      expect(b.zs.first, closeTo(9.81, 1e-6));
      expect(b.zs.last, closeTo(9.829, 1e-6));
      expect(b.minZ, closeTo(9.81, 1e-6));
      expect(b.maxZ, closeTo(9.829, 1e-6));
      // magnitude of a pure-Z sample equals |z|
      expect(b.magnitudeAt(0), closeTo(9.81, 1e-6));
      expect(b.summary(), contains('20 Hz'));
    });

    test('respects scale (a different fixed-point divisor)', () {
      final b = LiveBuffer();
      b.addFrame(chunk(1, samples: 4, scale: 100));
      // raw 9810 at scale=100 is 98.1 m/s² (i.e. the scale really is applied)
      expect(b.zs.first, closeTo(98.1, 1e-6));
    });

    test('the window is bounded but totals keep counting', () {
      final b = LiveBuffer(capacity: 50);
      for (var i = 1; i <= 5; i++) {
        b.addFrame(chunk(i, samples: 20));
      }
      expect(b.totalSamples, 100);
      expect(b.windowSamples, 50);
      expect(b.framesSeen, 5);
      expect(b.windowSeconds, closeTo(2.5, 1e-6));
    });

    test('clear() resets everything', () {
      final b = LiveBuffer();
      b.addFrame(chunk(1));
      b.clear();
      expect(b.totalSamples, 0);
      expect(b.windowSamples, 0);
      expect(b.peakMagnitude, 0);
      expect(b.summary(), 'no samples yet');
    });

    test('counts frames it could not use', () {
      final b = LiveBuffer();
      final bad = LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.chunk,
        seq: 1,
        timestampMs: 1,
        exerciseId: 1,
        rateHz: 20,
        flags: 0,
        scale: 1000,
        channels: const ['x'],
        samples: const [
          [1, 2], // arity 2 -> unusable
        ],
      );
      b.addFrame(bad);
      expect(b.framesRejected, 1);
      expect(b.totalSamples, 0);
    });
  });

  group('DebugLog', () {
    test('counts per tag and dumps oldest-first', () {
      final l = DebugLog();
      l.add('ble', 'advertising');
      l.add('frame', 'seq=1');
      l.add('frame', 'seq=2');
      expect(l.counts['frame'], 2);
      expect(l.entries.first.message, 'advertising');
      expect(l.dump().split('\n'), hasLength(3));
      expect(l.newestFirst.first.message, 'seq=2');
    });

    test('is bounded and notifies listeners', () {
      final l = DebugLog(capacity: 3);
      var notified = 0;
      l.addListener(() => notified++);
      for (var i = 0; i < 10; i++) {
        l.add('t', 'm$i');
      }
      expect(l.entries, hasLength(3));
      expect(notified, 10);
      l.clear();
      expect(l.entries, isEmpty);
      expect(l.counts, isEmpty);
    });

    test('line carries a timestamp and tag', () {
      final e = LogEntry('http', 'health OK');
      expect(e.line, contains('http'));
      expect(e.line, contains('health OK'));
      expect(e.line, matches(RegExp(r'^\d\d:\d\d:\d\d\.\d\d\d')));
    });
  });

  group('BackendClient.normalizeBase', () {
    test('appends /api/v1 when the path is missing', () {
      // This is the case that made the backend log 404s on /health.
      expect(BackendClient.normalizeBase('http://192.168.1.146:8008').path,
          '/api/v1');
      expect(BackendClient.normalizeBase('http://192.168.1.146:8008').toString(),
          'http://192.168.1.146:8008/api/v1');
    });

    test('adds a scheme when one is missing', () {
      expect(BackendClient.normalizeBase('192.168.1.146:8008/api/v1').toString(),
          'http://192.168.1.146:8008/api/v1');
    });

    test('leaves a correct URL alone and trims trailing slashes', () {
      expect(BackendClient.normalizeBase('http://host:8008/api/v1/').toString(),
          'http://host:8008/api/v1');
      expect(BackendClient.normalizeBase('http://host:8008/api/v1').toString(),
          'http://host:8008/api/v1');
    });

    test('empty input falls back to loopback:8008', () {
      expect(BackendClient.normalizeBase('').toString(),
          'http://127.0.0.1:8008/api/v1');
    });
  });
}
