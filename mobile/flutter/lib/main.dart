/// Liftosaur companion — Flutter phone app.
///
/// Pipeline: watch frames (docs/01) -> [SetSession] -> POST /api/v1/sets
/// (docs/02) -> physics + rep count shown in the UI.
///
/// The watch transport (docs/00 §4: BLE GATT peripheral vs
/// `Toybox.Communications`) is not wired yet, so the screen currently drives the
/// full pipeline from [SyntheticFrameSource]. That is deliberate: it exercises
/// every layer below the radio, so when the transport lands it is a single
/// `FrameSource` swap.
library;

import 'package:flutter/material.dart';

import 'backend_client.dart';
import 'ble_link.dart';
import 'frame_source.dart';
import 'set_session.dart';

void main() => runApp(const LiftosaurApp());

/// Backend on the self-hosted Hermes box (docs/02 dev base URL).
const String kDefaultBackend = 'http://192.168.1.146:8008/api/v1';

class LiftosaurApp extends StatelessWidget {
  const LiftosaurApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liftosaur Companion',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const CapturePage(),
    );
  }
}

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final _backendCtrl = TextEditingController(text: kDefaultBackend);
  final _weightCtrl = TextEditingController(text: '225');
  final _exerciseCtrl = TextEditingController(text: 'Squat');

  FrameSource? _source;
  BlePeripheralFrameSource? _ble;
  SetSession? _session;
  String _status = 'idle';
  String? _health;
  IngestResponse? _result;
  String? _error;
  bool _busy = false;

  BackendClient get _client => BackendClient(baseUrl: Uri.parse(_backendCtrl.text.trim()));

  @override
  void initState() {
    super.initState();
    // Kick off a health probe so the first screen tells you whether the
    // backend is reachable before you record anything.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkHealth());
  }

  @override
  void dispose() {
    _source?.stop();
    _backendCtrl.dispose();
    _weightCtrl.dispose();
    _exerciseCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    setState(() => _health = 'checking…');
    try {
      final body = await _client.health();
      setState(() => _health = 'ok · v${body['version']} · db=${body['db']}');
    } catch (e) {
      setState(() => _health = 'unreachable — $e');
    }
  }


  /// Wire a frame source into a fresh session and start it. Shared by the
  /// synthetic replay and the real BLE link so both exercise identical code.
  Future<void> _captureFrom(FrameSource src, {String label = ''}) async {
    final session = SetSession(
      userId: 'jonathan',
      exerciseId: 1,
      exerciseName:
          _exerciseCtrl.text.trim().isEmpty ? 'Squat' : _exerciseCtrl.text.trim(),
      prescribedWeightLbs: double.tryParse(_weightCtrl.text.trim()) ?? 225,
      watchModel: 'venu2s',
    );
    src.frames.listen((frame) {
      session.addFrame(frame);
      setState(() => _status = '${session.summary()}${_bleDetail()}');
    });
    setState(() {
      _source = src;
      _session = session;
      _result = null;
      _error = null;
      _status = 'starting $label…';
    });
    await src.start();
  }

  /// BLE-specific detail for the status line (link state, MTU, decode counters).
  String _bleDetail() {
    final ble = _ble;
    if (ble == null) return '';
    final parts = <String>[
      ble.isRunning ? 'ble:advertising' : 'ble:down',
      if (ble.negotiatedMtu != null) 'mtu=${ble.negotiatedMtu}',
      ble.assembler.summary(),
    ];
    return '\n${parts.join('  ')}';
  }

  /// Start the phone as a BLE peripheral and stream from the watch.
  Future<void> _startBle() async {
    final ble = BlePeripheralFrameSource();
    setState(() => _ble = ble);
    await _captureFrom(ble, label: 'BLE peripheral');
    if (!ble.isRunning) {
      setState(() => _error =
          'BLE peripheral did not start: ${ble.lastError ?? ble.lastState}');
    }
    if (mounted) setState(() {});
  }

  Future<void> _startCapture() async {
    final src = SyntheticFrameSource(rateHz: 20, seconds: 12, exerciseId: 1);
    await _captureFrom(src, label: 'synthetic set');
    if (mounted) {
      setState(() => _status = '${_session?.summary() ?? ''} (complete)');
    }
  }

  Future<void> _stopCapture() async {
    await _source?.stop();
    if (mounted) setState(() => _status = 'stopped');
  }

  Future<void> _upload() async {
    final session = _session;
    if (session == null) {
      setState(() => _error = 'not ready: no set captured yet');
      return;
    }
    final blockers = session.blockers();
    if (blockers.isNotEmpty) {
      setState(() => _error = 'not ready: ${blockers.join(', ')}');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final res = await _client.ingestSet(session.toBackendPayload());
      setState(() => _result = res);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('Liftosaur Companion')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _backendCtrl,
            decoration: const InputDecoration(
              labelText: 'Backend base URL',
              helperText: 'docs/02: http://<host>:8008/api/v1',
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('health: ${_health ?? '…'}')),
            TextButton(onPressed: _checkHealth, child: const Text('Recheck')),
          ]),
          const Divider(height: 32),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _exerciseCtrl,
                decoration: const InputDecoration(labelText: 'Exercise'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _weightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Weight (lbs)'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _startBle,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Start BLE link'),
            ),
            FilledButton.icon(
              onPressed: _startCapture,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Replay synthetic set'),
            ),
            OutlinedButton.icon(
              onPressed: _stopCapture,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _upload,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Upload set'),
            ),
          ]),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('capture: $_status'),
                if (session != null) ...[
                  const SizedBox(height: 6),
                  Text(session.summary()),
                  if (session.gapCount > 0)
                    Text('⚠ ${session.gapCount} seq gap(s) — dropped frames',
                        style: const TextStyle(color: Colors.orange)),
                  if (session.blockers().isNotEmpty)
                    Text('blockers: ${session.blockers().join(', ')}'),
                ],
                const SizedBox(height: 8),
                const Text(
                  'BLE link: this phone is the PERIPHERAL (GATT server) and the watch '
                  'is the central that writes chunk frames here — Garmin cannot make a '
                  'watch a peripheral. Start the BLE link, then run the watch app and '
                  'press Start. See docs/04-ble-transport.md.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ]),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_result != null) _ResultCard(result: _result!),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
  final IngestResponse result;

  @override
  Widget build(BuildContext context) {
    final p = result.physics;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('backend: HTTP ${result.statusCode}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          if (result.error != null)
            Text(result.error!, style: const TextStyle(color: Colors.red)),
          if (p != null) ...[
            const SizedBox(height: 8),
            Text('samples: ${result.nSamples}'),
            Text(p.toString()),
            Text('reps: ${result.repCount ?? "auto (Phase 5)"}'),
            if (!p.isPhysicallyPlausible)
              const Text('⚠ physics outside human range (docs/02 §5)',
                  style: TextStyle(color: Colors.orange)),
          ],
          if (result.warnings.isNotEmpty)
            Text('warnings: ${result.warnings.join(", ")}'),
        ]),
      ),
    );
  }
}
