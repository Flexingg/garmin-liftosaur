/// Liftosaur companion — phone app.
///
/// Pipeline: watch frames (docs/01) -> [SetSession] -> POST /api/v1/sets
/// (docs/02) -> physics + rep count.
///
/// BLE ROLES ARE INVERTED: Garmin's Connect IQ BLE API is central-only, so this
/// phone is the *peripheral* (GATT server) and the watch connects to us. See
/// docs/04-ble-transport.md.
///
/// While the link was being brought up the watch reported "sent=0, fail=0" and
/// nothing arrived, with no diagnostics anywhere: the watch's `System.println`
/// only goes to the Connect IQ developer console, never to `CIQ_LOG.YML`. Hence
/// the debug pane below — everything the phone observes is logged in-app, and
/// the link can be driven by hand.
library;

import 'package:flutter/material.dart';

import 'backend_client.dart';
import 'ble_link.dart';
import 'debug_log.dart';
import 'frame_source.dart';
import 'live_buffer.dart';
import 'live_chart.dart';
import 'protocol.dart';
import 'set_session.dart';

void main() => runApp(const LiftosaurApp());

/// Backend on the self-hosted Hermes box (docs/02; port 8008, not 8000 — 8000
/// is held by an unrelated container on that host).
const String kDefaultBackend = 'http://192.168.1.146:8008/api/v1';

class LiftosaurApp extends StatelessWidget {
  const LiftosaurApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liftosaur Companion',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const CompanionPage(),
    );
  }
}

class CompanionPage extends StatefulWidget {
  const CompanionPage({super.key});

  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends State<CompanionPage> {
  final _backendCtrl = TextEditingController(text: kDefaultBackend);
  final _weightCtrl = TextEditingController(text: '225');
  final _exerciseCtrl = TextEditingController(text: 'Squat');

  final DebugLog _log = DebugLog();
  final LiveBuffer _buffer = LiveBuffer();

  BlePeripheralFrameSource? _ble;
  FrameSource? _source;
  SetSession? _session;
  IngestResponse? _result;
  String? _error;
  String _status = 'idle';
  String? _health;
  bool _healthOk = false;
  bool _busy = false;
  ChartMode _chartMode = ChartMode.axes;
  int _lastFrameLogMs = 0;

  BackendClient get _client =>
      BackendClient(baseUrl: BackendClient.normalizeBase(_backendCtrl.text));

  @override
  void initState() {
    super.initState();
    _log.add('app', 'started; backend default $kDefaultBackend');
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

  // ------------------------------------------------------------------ backend

  Future<void> _checkHealth() async {
    final base = BackendClient.normalizeBase(_backendCtrl.text);
    setState(() => _health = 'checking $base …');
    try {
      final body = await _client.health();
      setState(() {
        _health = 'ok · v${body['version']} · db=${body['db']}';
        _healthOk = true;
      });
      _log.add('http', 'health OK at $base');
    } catch (e) {
      setState(() {
        _health = 'unreachable — $e';
        _healthOk = false;
      });
      _log.addError('http', e);
    }
  }

  // ----------------------------------------------------------------- capture

  void _onFrame(LiftFrame frame) {
    _buffer.addFrame(frame);
    _session?.addFrame(frame);

    // Throttle per-frame logging to ~1/s so state changes stay visible.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrameLogMs > 1000) {
      _lastFrameLogMs = now;
      _log.add('frame',
          'seq=${frame.seq} ${frame.rateHz}Hz n=${frame.sampleCount} '
          'flags=${frame.flags}');
    }
    setState(() {});
  }

  Future<void> _captureFrom(FrameSource src, {String label = ''}) async {
    final session = SetSession(
      userId: 'jonathan',
      exerciseId: 1,
      exerciseName:
          _exerciseCtrl.text.trim().isEmpty ? 'Squat' : _exerciseCtrl.text.trim(),
      prescribedWeightLbs: double.tryParse(_weightCtrl.text.trim()) ?? 225,
      watchModel: 'venu2s',
    );
    src.frames.listen(_onFrame);
    setState(() {
      _source = src;
      _session = session;
      _result = null;
      _error = null;
      _status = 'starting $label…';
    });
    await src.start();
    _log.add('src', 'started $label (${src.describe})');
  }

  Future<void> _startBle() async {
    final ble = BlePeripheralFrameSource();
    // Surface everything the link observes into the in-app log: the watch cannot
    // tell us anything (its System.println never reaches CIQ_LOG.YML).
    ble.events.listen((msg) {
      _log.add('ble', msg);
      if (mounted) setState(() {});
    });
    setState(() => _ble = ble);
    await _captureFrom(ble, label: 'BLE peripheral');
    if (!ble.isRunning) {
      setState(() => _error =
          'BLE peripheral did not start: ${ble.lastError ?? ble.lastState}');
      _log.add('ble', 'NOT advertising: ${ble.lastError ?? ble.lastState}');
    } else {
      _log.add('ble', 'advertising as "$kLiftLocalName" '
          'service=$kLiftServiceUuid rx=$kLiftDataUuid');
    }
    if (mounted) setState(() {});
  }

  Future<void> _stopBle() async {
    await _ble?.stop();
    _log.add('ble', 'advertising stopped');
    setState(() {});
  }

  /// Push a synthetic frame through the exact same path a real one takes, so
  /// decode + chart + session + upload can be verified with no watch involved.
  void _injectTestFrame() {
    final rows = <List<int>>[];
    for (var i = 0; i < 20; i++) {
      final t = i / 20;
      rows.add([
        (0.4 * 1000 * (t - 0.5)).round(),
        (0.3 * 1000 * (t - 0.5)).round(),
        ((9.81 + 2.0 * (t - 0.5)) * 1000).round(),
      ]);
    }
    final frame = LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.chunk,
      seq: 900 + _buffer.framesSeen,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      exerciseId: 1,
      rateHz: 20,
      flags: 0,
      scale: 1000,
      channels: const ['x', 'y', 'z'],
      samples: rows,
    );
    _log.add('inject', 'synthetic frame n=${rows.length} (bypasses BLE)');
    _onFrame(frame);
  }

  // ------------------------------------------------------------------ upload

  Future<void> _upload() async {
    final session = _session;
    if (session == null) {
      setState(() => _error = 'not ready: no set captured yet');
      _log.add('upload', 'refused: no set captured');
      return;
    }
    final blockers = session.blockers();
    if (blockers.isNotEmpty) {
      setState(() => _error = 'not ready: ${blockers.join(', ')}');
      _log.add('upload', 'refused: ${blockers.join(', ')}');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final base = BackendClient.normalizeBase(_backendCtrl.text);
    _log.add('upload', 'POST $base/sets (${session.sampleCount} samples)');
    try {
      final res = await _client.ingestSet(session.toBackendPayload());
      setState(() => _result = res);
      _log.add('upload', 'HTTP ${res.statusCode} n=${res.nSamples} ${res.physics ?? res.error}');
    } catch (e) {
      setState(() => _error = '$e');
      _log.addError('upload', e);
    } finally {
      setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final ble = _ble;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Liftosaur Companion'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Capture'),
            Tab(text: 'Debug'),
          ]),
        ),
        body: TabBarView(children: [
          _captureTab(session),
          _debugTab(ble),
        ]),
      ),
    );
  }

  Widget _captureTab(SetSession? session) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _backendCtrl,
          decoration: const InputDecoration(
            labelText: 'Backend base URL',
            helperText: 'bare host:port is fine — /api/v1 is filled in',
          ),
          onSubmitted: (_) => _checkHealth(),
        ),
        Row(children: [
          Expanded(
            child: Text('health: ${_health ?? '…'}',
                style: TextStyle(
                    color: _healthOk ? Colors.green.shade600 : null)),
          ),
          TextButton(onPressed: _checkHealth, child: const Text('Recheck')),
        ]),
        const Divider(height: 24),
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
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: _startBle,
            icon: const Icon(Icons.bluetooth),
            label: const Text('Start BLE link'),
          ),
          OutlinedButton.icon(
            onPressed: _stopBle,
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Stop advertising'),
          ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _upload,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('Upload set'),
          ),
        ]),
        const SizedBox(height: 12),
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
                'This phone is the BLE PERIPHERAL (GATT server); the watch is the '
                'central and writes chunks here. Garmin cannot make a watch a '
                'peripheral. See docs/04-ble-transport.md.',
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
        const SizedBox(height: 24),
        const Text('Live accelerometer', style: TextStyle(fontWeight: FontWeight.bold)),
        LiveChart(buffer: _buffer, mode: _chartMode),
        Row(children: [
          Expanded(child: Text(_buffer.summary(), style: const TextStyle(fontSize: 12))),
          SegmentedButton<ChartMode>(
            segments: const [
              ButtonSegment(value: ChartMode.axes, label: Text('X/Y/Z')),
              ButtonSegment(value: ChartMode.magnitude, label: Text('|a|')),
            ],
            selected: {_chartMode},
            onSelectionChanged: (s) => setState(() => _chartMode = s.first),
          ),
        ]),
      ],
    );
  }

  Widget _debugTab(BlePeripheralFrameSource? ble) {
    final counts = _log.counts.entries.map((e) => '${e.key}:${e.value}').join('  ');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('link: ${ble == null ? 'not started' : (ble.isRunning ? 'ADVERTISING' : 'stopped')}'
              '${ble?.negotiatedMtu != null ? '  mtu=${ble!.negotiatedMtu}' : ''}'),
          Text('advertising (platform-reported): ${ble?.advertisingNow ?? false}'
              '   central connected: ${ble?.centralConnected ?? false}'
              '${(ble?.centralConnects ?? 0) > 0 ? ' (${ble!.centralConnects}x)' : ''}'),
          Text('state: ${ble?.lastState ?? '-'}   '
              'gatt writes: ${ble?.gattWrites ?? 0}  last char: ${ble?.lastWriteCharacteristic ?? "none"}'),
          Text('fragments: ${ble?.assembler.summary() ?? '-'}'),
          Text('buffer: ${_buffer.summary()}'),
          const SizedBox(height: 6),
          Text('events: $counts', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: _startBle, child: const Text('Start advertising')),
            OutlinedButton(onPressed: _stopBle, child: const Text('Stop')),
            OutlinedButton(onPressed: _injectTestFrame, child: const Text('Inject test frame')),
            OutlinedButton(onPressed: _clearAll, child: const Text('Clear chart + log')),
          ]),
        ]),
      ),
      const Divider(height: 1),
      Row(children: [
        const Padding(padding: EdgeInsets.all(8), child: Text('log (newest first)')),
        const Spacer(),
        TextButton(
          onPressed: () => setState(_log.clear),
          child: const Text('Clear log'),
        ),
      ]),
      Expanded(
        child: Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _log.newestFirst.length,
            itemBuilder: (_, i) => Text(
              _log.newestFirst[i].line,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ),
    ]);
  }

  void _clearAll() {
    _buffer.clear();
    _log.clear();
    _log.add('app', 'chart + log cleared');
    setState(() {});
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
