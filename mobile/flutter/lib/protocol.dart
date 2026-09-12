/// Watch -> phone wire protocol (docs/01-ble-payload-data-contract.md).
///
/// Implements the dictionary/JSON form (docs/01 §7) that the watch emits via
/// [LiftFrame] on the Monkey C side. Everything here is pure Dart with no
/// Flutter/plugin dependency so it can be unit-tested without a device.
library;

/// Protocol version this client speaks. Frames with a different version are
/// accepted but flagged, never silently reinterpreted.
const int liftProtocolVersion = 1;

/// docs/01 §1 frame types.
enum FrameType { hello, chunk, setEnd, cmd, unknown }

FrameType frameTypeFromWire(String? wire) => switch (wire) {
      'hello' => FrameType.hello,
      'chunk' => FrameType.chunk,
      'set_end' => FrameType.setEnd,
      'cmd' => FrameType.cmd,
      _ => FrameType.unknown,
    };

/// docs/01 §2 header flag bits.
const int flagChunkEnd = 0x01;
const int flagGravityKnown = 0x02;

/// Bit positions in the CHUNK `channel_mask` (docs/01 §3): bit0=X, bit1=Y, bit2=Z.
const int channelMaskXYZ = 0x07;

/// One decoded frame off the wire.
class LiftFrame {
  final int version;
  final FrameType type;
  final int seq;
  final int timestampMs;
  final int exerciseId;
  final int rateHz;
  final int flags;

  /// Fixed-point divisor: `accel_m_s2 = raw / scale` (docs/01 §3).
  final int scale;
  final List<String> channels;

  /// Raw int16 samples, X/Y/Z interleaved per sample.
  final List<List<int>> samples;

  /// SET_END only.
  final int? durationMs;
  final int? repHint;

  const LiftFrame({
    required this.version,
    required this.type,
    required this.seq,
    required this.timestampMs,
    required this.exerciseId,
    required this.rateHz,
    required this.flags,
    required this.scale,
    required this.channels,
    required this.samples,
    this.durationMs,
    this.repHint,
  });

  bool get isChunkEnd => (flags & flagChunkEnd) != 0;
  bool get gravityKnown => (flags & flagGravityKnown) != 0;

  /// Number of samples in the chunk.
  int get sampleCount => samples.length;

  /// Convert one raw channel value to m/s² (docs/01 §3).
  double toMs2(int raw) => scale == 0 ? 0 : raw / scale;

  /// Expected wall-clock spacing between samples at the declared rate.
  /// Consumers MUST use `rateHz` as ground truth rather than assuming 100 Hz
  /// (docs/01 §4).
  Duration get samplePeriod =>
      rateHz <= 0 ? Duration.zero : Duration(microseconds: 1000000 ~/ rateHz);

  /// Timestamp of sample [index] within this chunk.
  DateTime sampleTime(int index) =>
      DateTime.fromMillisecondsSinceEpoch(timestampMs).add(samplePeriod * index);

  /// Structural validation. Returns human-readable problems; empty == clean.
  /// Deliberately does not throw so a single bad frame cannot kill a session.
  List<String> validate() {
    final problems = <String>[];
    if (version != liftProtocolVersion) {
      problems.add('protocol version $version != $liftProtocolVersion');
    }
    if (seq < 0) problems.add('negative seq');
    if (rateHz <= 0) problems.add('rate_hz must be > 0 (got $rateHz)');
    if (scale <= 0) problems.add('scale must be > 0 (got $scale)');
    if (type == FrameType.chunk) {
      for (final row in samples) {
        if (row.length != 3) {
          problems.add('sample row arity ${row.length} != 3');
          break;
        }
      }
      if (channels.isEmpty) problems.add('chunk carries no channels');
    }
    return problems;
  }

  /// Decode the docs/01 §7 dictionary form.
  ///
  /// Throws [FormatException] on a frame too malformed to reason about (e.g.
  /// missing `type`); softer issues are reported by [validate].
  factory LiftFrame.fromWire(Map<dynamic, dynamic> json) {
    final type = frameTypeFromWire(json['type'] as String?);
    if (type == FrameType.unknown) {
      throw FormatException('unknown frame type: ${json['type']}');
    }

    final rawSamples = json['samples'];
    final samples = <List<int>>[];
    if (rawSamples is List) {
      for (final row in rawSamples) {
        if (row is List && row.length == 3) {
          samples.add([for (final v in row) (v as num).toInt()]);
        }
      }
    }

    final rawChannels = json['channels'];
    final channels = rawChannels is List
        ? [for (final c in rawChannels) c.toString()]
        : const <String>[];

    return LiftFrame(
      version: (json['v'] as num?)?.toInt() ?? liftProtocolVersion,
      type: type,
      seq: (json['seq'] as num?)?.toInt() ?? -1,
      timestampMs: (json['ts'] as num?)?.toInt() ?? 0,
      exerciseId: (json['exercise_id'] as num?)?.toInt() ?? 0,
      rateHz: (json['rate_hz'] as num?)?.toInt() ?? 0,
      flags: (json['flags'] as num?)?.toInt() ?? 0,
      scale: (json['scale'] as num?)?.toInt() ?? 1000,
      channels: channels,
      samples: samples,
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      repHint: (json['rep_hint'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'LiftFrame(${type.name} seq=$seq rate=${rateHz}Hz n=$sampleCount '
      'flags=$flags)';
}
