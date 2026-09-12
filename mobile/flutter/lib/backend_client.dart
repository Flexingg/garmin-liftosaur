/// Backend client for the Flutter -> Python contract (docs/02).
///
/// Uses `dart:io` HttpClient directly rather than package:http so the app needs
/// no third-party dependencies to talk to the ingest API — which keeps it
/// runnable on desktop for development and testable with a real local server.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown when the backend is unreachable or returns a non-JSON body.
class BackendException implements Exception {
  final String message;
  BackendException(this.message);
  @override
  String toString() => 'BackendException: $message';
}

/// Physics block from a successful ingest (docs/02 §1).
class PhysicsResult {
  final double peakVelocityMs;
  final double peakPowerW;
  final double meanPowerW;
  final double displacementM;
  final double durationS;

  const PhysicsResult({
    required this.peakVelocityMs,
    required this.peakPowerW,
    required this.meanPowerW,
    required this.displacementM,
    required this.durationS,
  });

  factory PhysicsResult.fromJson(Map<String, dynamic> json) => PhysicsResult(
        peakVelocityMs: (json['peak_velocity_m_s'] as num?)?.toDouble() ?? 0,
        peakPowerW: (json['peak_power_w'] as num?)?.toDouble() ?? 0,
        meanPowerW: (json['mean_power_w'] as num?)?.toDouble() ?? 0,
        displacementM: (json['displacement_m'] as num?)?.toDouble() ?? 0,
        durationS: (json['duration_s'] as num?)?.toDouble() ?? 0,
      );

  /// docs/02 §5: human-plausible peak power is roughly 200-1500 W.
  /// Anything wildly outside that means filtering/integration bugs upstream.
  bool get isPhysicallyPlausible =>
      peakPowerW >= 10 && peakPowerW <= 3000 && peakVelocityMs <= 5;

  @override
  String toString() => 'peak ${peakPowerW.toStringAsFixed(0)}W '
      'mean ${meanPowerW.toStringAsFixed(0)}W '
      'v ${peakVelocityMs.toStringAsFixed(2)}m/s '
      'd ${displacementM.toStringAsFixed(2)}m';
}

/// Outcome of POST /api/v1/sets.
class IngestResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const IngestResponse(this.statusCode, this.body);

  bool get ok => statusCode >= 200 && statusCode < 300;
  int? get nSamples => (body['n_samples'] as num?)?.toInt();
  int? get repCount => (body['rep_count'] as num?)?.toInt();
  String? get setId => body['set_id'] as String?;

  PhysicsResult? get physics {
    final p = body['physics'];
    return p is Map ? PhysicsResult.fromJson(Map<String, dynamic>.from(p)) : null;
  }

  List<String> get warnings {
    final w = body['warnings'];
    return w is List ? [for (final e in w) e.toString()] : const <String>[];
  }

  String? get error {
    final e = body['error'] ?? body['detail'];
    return e?.toString();
  }
}

/// Minimal HTTP client for the ingest API.
class BackendClient {
  final Uri baseUrl;
  final Duration timeout;
  final HttpClient _client;

  BackendClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 15),
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  /// Convenience: `BackendClient.forHost('192.168.1.146')`.
  factory BackendClient.forHost(String host, {int port = 8008, HttpClient? client}) =>
      BackendClient(
        baseUrl: Uri.parse('http://$host:$port/api/v1'),
        client: client,
      );

  Uri _endpoint(String path) => baseUrl.replace(
        path: '${baseUrl.path.replaceAll(RegExp(r'/+$'), '')}$path',
      );

  Future<Map<String, dynamic>> health() async {
    final body = await _send('GET', '/health');
    return body;
  }

  Future<IngestResponse> ingestSet(Map<String, dynamic> payload) async {
    final (status, body) = await _sendRaw('POST', '/sets', payload);
    return IngestResponse(status, body);
  }

  Future<Map<String, dynamic>> _send(String method, String path,
      [Map<String, dynamic>? payload]) async {
    final (_, body) = await _sendRaw(method, path, payload);
    return body;
  }

  Future<(int, Map<String, dynamic>)> _sendRaw(
      String method, String path, [Map<String, dynamic>? payload]) async {
    final uri = _endpoint(path);
    HttpClientRequest req;
    try {
      req = await _client.openUrl(method, uri).timeout(timeout);
    } on SocketException catch (e) {
      throw BackendException('cannot reach $uri: ${e.message}');
    } on TimeoutException {
      throw BackendException('timed out opening $uri');
    }

    req.headers.contentType = ContentType.json;
    if (payload != null) {
      req.add(utf8.encode(jsonEncode(payload)));
    }

    HttpClientResponse res;
    try {
      res = await req.close().timeout(timeout);
    } on SocketException catch (e) {
      throw BackendException('request to $uri failed: ${e.message}');
    } on TimeoutException {
      throw BackendException('timed out sending to $uri');
    }

    final raw = await res.transform(utf8.decoder).join().timeout(timeout);
    if (raw.trim().isEmpty) return (res.statusCode, <String, dynamic>{});
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return (res.statusCode, Map<String, dynamic>.from(decoded));
      return (res.statusCode, <String, dynamic>{'body': decoded});
    } on FormatException {
      return (res.statusCode, <String, dynamic>{'error': 'non-JSON response', 'raw': raw});
    }
  }

  void close() => _client.close(force: true);
}
