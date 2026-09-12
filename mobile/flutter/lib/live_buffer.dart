/// Rolling sample buffer + stats for the live accelerometer view.
///
/// Pure Dart (no Flutter) so the maths is unit-tested; the widget layer only
/// paints what this exposes.
library;

import 'dart:math' as math;

import 'protocol.dart';

/// A rolling window of accelerometer values, in m/s², ready to plot.
class LiveBuffer {
  /// Samples retained for the chart (at 20 Hz, 600 ≈ 30 s).
  final int capacity;

  final List<double> xs = [];
  final List<double> ys = [];
  final List<double> zs = [];

  /// Cumulative samples seen since the last [clear] — not window-limited.
  int totalSamples = 0;
  int framesSeen = 0;
  int framesRejected = 0;

  double peakMagnitude = 0;
  double sumMagnitude = 0;
  double minZ = double.infinity;
  double maxZ = -double.infinity;

  /// Declared rate from the most recent frame (ground truth per docs/01 §4).
  int rateHz = 0;

  /// Timestamp (epoch ms) of the newest and oldest samples in the window.
  int? newestTsMs;
  int? oldestTsMs;

  LiveBuffer({this.capacity = 600});

  int get windowSamples => xs.length;
  double get meanMagnitude =>
      totalSamples == 0 ? 0 : sumMagnitude / totalSamples;

  /// Seconds of data currently held in the window.
  double get windowSeconds => rateHz <= 0 ? 0 : xs.length / rateHz;

  /// Append one frame's samples. Malformed frames are counted, not fatal.
  void addFrame(LiftFrame frame) {
    framesSeen++;
    final scale = frame.scale <= 0 ? 1000 : frame.scale;
    var added = 0;
    for (final row in frame.samples) {
      if (row.length < 3) {
        continue;
      }
      final x = row[0] / scale;
      final y = row[1] / scale;
      final z = row[2] / scale;
      xs.add(x);
      ys.add(y);
      zs.add(z);
      totalSamples++;
      added++;

      final mag = _magnitude(x, y, z);
      if (mag > peakMagnitude) peakMagnitude = mag;
      sumMagnitude += mag;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    if (added == 0 && frame.samples.isNotEmpty) framesRejected++;
    if (frame.rateHz > 0) rateHz = frame.rateHz;
    if (frame.samples.isNotEmpty) {
      newestTsMs = frame.timestampMs;
      final firstInWindow = frame.timestampMs -
          (frame.samples.length - 1) * (1000 ~/ (frame.rateHz == 0 ? 20 : frame.rateHz));
      oldestTsMs ??= firstInWindow;
    }
    _trim();
  }

  /// Push a single pre-scaled sample (used by tests and the inject button).
  void addSample(double x, double y, double z) {
    xs.add(x);
    ys.add(y);
    zs.add(z);
    totalSamples++;
    final mag = _magnitude(x, y, z);
    if (mag > peakMagnitude) peakMagnitude = mag;
    sumMagnitude += mag;
    if (z < minZ) minZ = z;
    if (z > maxZ) maxZ = z;
    _trim();
  }

  void _trim() {
    final over = xs.length - capacity;
    if (over <= 0) return;
    xs.removeRange(0, over);
    ys.removeRange(0, over);
    zs.removeRange(0, over);
  }

  /// Vector magnitude, m/s². Peaks are tracked on this value.
  static double _magnitude(double x, double y, double z) =>
      math.sqrt(x * x + y * y + z * z);

  /// Magnitude of sample [i] in the window — what the chart plots.
  double magnitudeAt(int i) => _magnitude(xs[i], ys[i], zs[i]);

  void clear() {
    xs.clear();
    ys.clear();
    zs.clear();
    totalSamples = 0;
    framesSeen = 0;
    framesRejected = 0;
    peakMagnitude = 0;
    sumMagnitude = 0;
    minZ = double.infinity;
    maxZ = -double.infinity;
    newestTsMs = null;
    oldestTsMs = null;
  }

  String summary() {
    if (totalSamples == 0) return 'no samples yet';
    return 'n=$totalSamples window=${xs.length} $rateHz Hz '
        '${windowSeconds.toStringAsFixed(1)}s '
        'peak=${peakMagnitude.toStringAsFixed(1)} '
        'mean=${meanMagnitude.toStringAsFixed(1)} m/s²'
        '${framesRejected > 0 ? ' rejected=$framesRejected' : ''}';
  }
}
