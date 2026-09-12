// End-to-end smoke test: synthetic watch frames -> SetSession -> real backend.
//
//   cd backend/python && ./.venv/bin/uvicorn app.main:app --port 8000
//   cd mobile/flutter && ~/flutter/bin/dart run tool/smoke_e2e.dart [baseUrl]
//
// Imports only the pure-Dart layers of the package (no Flutter), so it runs on
// the Dart VM. Exits non-zero if the pipeline or the physics sanity checks fail.

import 'dart:io';

import 'package:liftosaur_garmin/backend_client.dart';
import 'package:liftosaur_garmin/frame_source.dart';
import 'package:liftosaur_garmin/set_session.dart';

Future<int> main(List<String> args) async {
  final base = args.isNotEmpty ? args.first : 'http://127.0.0.1:8000/api/v1';
  final client = BackendClient(baseUrl: Uri.parse(base));

  stdout.writeln('backend: $base');
  final health = await client.health();
  stdout.writeln('health : $health');

  final session = SetSession(
    userId: 'jonathan',
    exerciseId: 1,
    exerciseName: 'Squat (synthetic)',
    prescribedWeightLbs: 225,
    setNumber: 1,
    watchModel: 'venu2s',
  );

  final source = SyntheticFrameSource(rateHz: 20, seconds: 12);
  final done = source.frames.listen(session.addFrame).asFuture<void>();
  await source.start();
  await source.stop();
  await done;

  stdout.writeln('capture: ${session.summary()}');
  stdout.writeln('blockers: ${session.blockers()}');
  if (!session.isReady) {
    stderr.writeln('FAIL: session not uploadable');
    return 1;
  }

  final payload = session.toBackendPayload();
  stdout.writeln('payload: ${payload['samples'] is List ? (payload['samples'] as List).length : 0} samples, '
      'rate=${payload['sample_rate_hz']}Hz mask=${payload['channel_mask']} scale=${payload['scale']}');

  final res = await client.ingestSet(payload);
  stdout.writeln('HTTP ${res.statusCode}  n_samples=${res.nSamples}  reps=${res.repCount}');
  if (res.error != null) stdout.writeln('error: ${res.error}');
  if (res.warnings.isNotEmpty) stdout.writeln('warnings: ${res.warnings.join(", ")}');

  final p = res.physics;
  if (!res.ok || p == null) {
    stderr.writeln('FAIL: no physics block (HTTP ${res.statusCode})');
    return 1;
  }
  stdout.writeln('physics: $p');

  // docs/02 §5: catch the "10,000 watts" class of bug.
  final checks = <String, bool>{
    'peak_velocity 0.01..5 m/s': p.peakVelocityMs > 0.01 && p.peakVelocityMs <= 5,
    'peak_power <= 3000 W': p.peakPowerW <= 3000,
    'duration > 0 s': p.durationS > 0,
  };
  checks.forEach((k, v) => stdout.writeln('  ${v ? "PASS" : "FAIL"}  $k'));
  final failed = checks.values.where((v) => !v).length;
  stdout.writeln(failed == 0 ? 'E2E OK' : 'E2E FAILED ($failed check(s))');
  client.close();
  return failed == 0 ? 0 : 1;
}
