import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/backend_client.dart';

/// Exercises the client against a REAL local HTTP server, so the request body
/// is validated end-to-end against the docs/02 contract rather than a mock.
void main() {
  late HttpServer server;
  late Uri baseUrl;
  late List<Map<String, dynamic>> received;

  setUp(() async {
    received = <Map<String, dynamic>>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = Uri.parse('http://127.0.0.1:${server.port}/api/v1');

    server.listen((HttpRequest req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/api/v1/health') {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok', 'version': '0.2.0', 'db': 'not_configured'}));
      } else if (req.uri.path == '/api/v1/sets') {
        final payload = jsonDecode(body) as Map<String, dynamic>;
        received.add(payload);
        final missing = [
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
        ].where((k) => !payload.containsKey(k)).toList();
        if (missing.isNotEmpty) {
          req.response
            ..statusCode = 422
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'unprocessable', 'detail': 'missing $missing'}));
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'set_id': 'pending',
              'status': 'ok',
              'n_samples': (payload['samples'] as List).length,
              'physics': {
                'peak_velocity_m_s': 1.12,
                'peak_power_w': 345.0,
                'mean_power_w': 214.0,
                'displacement_m': 0.42,
                'duration_s': 28.0,
              },
              'rep_count': null,
              'warnings': ['low_sample_rate'],
            }));
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  test('health() decodes the liveness payload (docs/02 §2)', () async {
    final c = BackendClient(baseUrl: baseUrl);
    final body = await c.health();
    expect(body['status'], 'ok');
    expect(body['version'], '0.2.0');
    c.close();
  });

  test('ingestSet() sends a contract-shaped body and decodes physics', () async {
    final c = BackendClient(baseUrl: baseUrl);
    final res = await c.ingestSet({
      'user_id': 'jonathan',
      'exercise_id': 1,
      'exercise_name': 'Squat',
      'prescribed_weight_lbs': 225.0,
      'started_at': '2026-09-12T10:00:00.000Z',
      'ended_at': '2026-09-12T10:00:12.000Z',
      'sample_rate_hz': 20,
      'channel_mask': 7,
      'scale': 1000,
      'samples': [
        [0, 0, 9810],
        [10, 5, 9900],
        [-10, -5, 9700],
        [0, 0, 9810],
      ],
      'watch_model': 'venu2s',
      'rep_hint': 0,
    });

    expect(res.ok, isTrue);
    expect(res.statusCode, 200);
    expect(res.nSamples, 4);
    expect(res.warnings, contains('low_sample_rate'));
    expect(res.physics, isNotNull);
    expect(res.physics!.peakPowerW, closeTo(345, 1e-9));
    expect(res.physics!.isPhysicallyPlausible, isTrue);

    // the server actually received contract fields
    expect(received, hasLength(1));
    expect(received.single['sample_rate_hz'], 20);
    expect(received.single['channel_mask'], 7);
    expect((received.single['samples'] as List), hasLength(4));
    c.close();
  });

  test('surfaces a backend 422 rather than throwing', () async {
    final c = BackendClient(baseUrl: baseUrl);
    final res = await c.ingestSet({'user_id': 'jonathan'}); // missing fields
    expect(res.ok, isFalse);
    expect(res.statusCode, 422);
    expect(res.error, 'unprocessable');
    expect(res.body['detail'], contains('missing'));
    c.close();
  });

  test('an unreachable backend raises BackendException', () async {
    // port 1 is reserved/unbindable in practice
    final c = BackendClient(baseUrl: Uri.parse('http://127.0.0.1:1/api/v1'),
        timeout: const Duration(milliseconds: 500));
    expect(() => c.health(), throwsA(isA<BackendException>()));
    c.close();
  });
}
