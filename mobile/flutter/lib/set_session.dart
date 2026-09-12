/// Accumulates watch frames into one set and renders the backend payload
/// (docs/01 -> docs/02). Pure Dart, no Flutter dependency: unit-testable.
library;

import 'protocol.dart';

/// Result of feeding frames into a session.
enum IngestResult { accepted, duplicate, gap, afterEnd, rejected }

/// One workout set assembled from CHUNK frames, finalized by SET_END.
class SetSession {
  final String userId;
  final int exerciseId;
  final String exerciseName;
  final double prescribedWeightLbs;
  final int? setNumber;
  final String watchModel;

  final List<List<int>> _samples = <List<int>>[];
  final List<String> warnings = <String>[];

  int rateHz = 0;
  int scale = 1000;
  int channelMask = channelMaskXYZ;
  int? seqStart;
  int? seqEnd;
  int? _lastSeq;
  int _lastTimestampMs = 0;

  int chunkCount = 0;
  int gapCount = 0;
  int duplicateSeq = 0;
  int droppedRows = 0;
  bool ended = false;
  int? durationMs;
  int repHint = 0;

  SetSession({
    required this.userId,
    required this.exerciseId,
    required this.exerciseName,
    required this.prescribedWeightLbs,
    this.setNumber,
    this.watchModel = 'venu2s',
  });

  int get sampleCount => _samples.length;
  List<List<int>> get samples => List.unmodifiable(_samples);

  /// Wall-clock start of the set (first frame seen), or null if empty.
  DateTime? get startedAt => seqStart == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_firstTimestampMs, isUtc: true);

  DateTime? get endedAt {
    if (!ended) return null;
    if (durationMs != null) {
      return DateTime.fromMillisecondsSinceEpoch(
          _firstTimestampMs + durationMs!, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(_lastTimestampMs, isUtc: true);
  }

  int _firstTimestampMs = 0;

  /// Real elapsed seconds covered by the samples we actually hold.
  double get capturedSeconds =>
      rateHz <= 0 ? 0 : _samples.length / rateHz;

  /// Feed one frame. Never throws — bad frames are counted, not fatal.
  IngestResult addFrame(LiftFrame frame) {
    if (ended) return IngestResult.afterEnd;

    final problems = frame.validate();
    if (problems.isNotEmpty) {
      // A malformed chunk shouldn't abort the set: record and keep going.
      warnings.add('frame seq=${frame.seq}: ${problems.join('; ')}');
      return IngestResult.rejected;
    }

    switch (frame.type) {
      case FrameType.hello:
        rateHz = frame.rateHz;
        scale = frame.scale;
        if (frame.channels.isNotEmpty) {
          channelMask = _maskFor(frame.channels);
        }
        return IngestResult.accepted;

      case FrameType.chunk:
        if (_lastSeq != null) {
          if (frame.seq <= _lastSeq!) {
            duplicateSeq++;
            return IngestResult.duplicate;
          }
          // docs/01 §8: contiguous seq; a jump means lost frames.
          if (frame.seq != _lastSeq! + 1) {
            gapCount++;
            warnings.add('seq gap ${_lastSeq! + 1}..${frame.seq - 1}');
          }
        }
        seqStart ??= frame.seq;
        _firstTimestampMs = seqStart == frame.seq ? frame.timestampMs : _firstTimestampMs;
        _lastTimestampMs = frame.timestampMs;
        rateHz = frame.rateHz > 0 ? frame.rateHz : rateHz;
        scale = frame.scale > 0 ? frame.scale : scale;
        _lastSeq = frame.seq;

        for (final row in frame.samples) {
          if (row.length == 3) {
            _samples.add(row);
          } else {
            droppedRows++;
          }
        }
        chunkCount++;
        return gapCount > 0 && warnings.last.startsWith('seq gap')
            ? IngestResult.gap
            : IngestResult.accepted;

      case FrameType.setEnd:
        durationMs = frame.durationMs;
        repHint = frame.repHint ?? 0;
        seqEnd = _lastSeq;
        ended = true;
        return IngestResult.accepted;

      case FrameType.cmd:
        return IngestResult.accepted;

      case FrameType.unknown:
        return IngestResult.rejected;
    }
  }

  static int _maskFor(List<String> channels) {
    var mask = 0;
    for (final c in channels) {
      final v = c.toLowerCase().trim();
      if (v == 'x' || v.startsWith('accel_x')) mask |= 0x01;
      if (v == 'y' || v.startsWith('accel_y')) mask |= 0x02;
      if (v == 'z' || v.startsWith('accel_z')) mask |= 0x04;
    }
    return mask == 0 ? channelMaskXYZ : mask;
  }

  /// Reasons this set cannot be uploaded yet. Empty == ready.
  List<String> blockers() {
    final out = <String>[];
    if (_samples.isEmpty) out.add('no samples captured');
    // The backend rejects fewer than 4 samples (HTTP 422).
    if (_samples.isNotEmpty && _samples.length < 4) {
      out.add('need >=4 samples, have ${_samples.length}');
    }
    if (rateHz <= 0) out.add('no sample rate reported');
    if (scale <= 0) out.add('invalid scale');
    return out;
  }

  bool get isReady => blockers().isEmpty;

  /// docs/02 §1 request body. Only call when [isReady].
  Map<String, dynamic> toBackendPayload() {
    if (!isReady) {
      throw StateError('set not ready: ${blockers().join(', ')}');
    }
    final start = startedAt!;
    final end = endedAt ?? start.add(Duration(milliseconds: durationMs ?? 0));
    return <String, dynamic>{
      'user_id': userId,
      'exercise_id': exerciseId,
      'exercise_name': exerciseName,
      'prescribed_weight_lbs': prescribedWeightLbs,
      if (setNumber != null) 'set_number': setNumber,
      'started_at': start.toIso8601String(),
      'ended_at': end.toIso8601String(),
      'sample_rate_hz': rateHz,
      'channel_mask': channelMask,
      'scale': scale,
      'samples': _samples,
      if (seqStart != null) 'seq_start': seqStart,
      if (seqEnd != null) 'seq_end': seqEnd,
      'watch_model': watchModel,
      'rep_hint': repHint,
    };
  }

  /// Human-readable capture summary for the UI.
  String summary() =>
      'chunks=$chunkCount samples=$sampleCount ${rateHz}Hz '
      '${capturedSeconds.toStringAsFixed(1)}s'
      '${gapCount > 0 ? ' gaps=$gapCount' : ''}'
      '${duplicateSeq > 0 ? ' dup=$duplicateSeq' : ''}'
      '${ended ? ' ENDED' : ''}';
}
