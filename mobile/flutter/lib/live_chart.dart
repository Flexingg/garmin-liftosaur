/// Live accelerometer chart — dependency-free CustomPainter.
library;

import 'package:flutter/material.dart';

import 'live_buffer.dart';

/// What the chart plots.
enum ChartMode { magnitude, axes }

class LiveChart extends StatelessWidget {
  const LiveChart({
    super.key,
    required this.buffer,
    this.mode = ChartMode.axes,
    this.height = 170,
  });

  final LiveBuffer buffer;
  final ChartMode mode;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LiveChartPainter(
          buffer: buffer,
          mode: mode,
          grid: scheme.outlineVariant,
          text: scheme.onSurfaceVariant,
          x: scheme.primary,
          y: scheme.tertiary,
          z: scheme.error,
        ),
      ),
    );
  }
}

class _LiveChartPainter extends CustomPainter {
  _LiveChartPainter({
    required this.buffer,
    required this.mode,
    required this.grid,
    required this.text,
    required this.x,
    required this.y,
    required this.z,
  });

  final LiveBuffer buffer;
  final ChartMode mode;
  final Color grid, text, x, y, z;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Frame + horizontal gridlines.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), gridPaint);
    for (var i = 1; i < 4; i++) {
      final dy = size.height * i / 4;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), gridPaint);
    }

    final n = buffer.xs.length;
    if (n < 2) {
      _label(canvas, size, 'waiting for samples…');
      return;
    }

    // Auto-scale to the data actually on screen, with headroom, and keep 0 in
    // view so the gravity baseline is obvious.
    double lo = 0, hi = 0;
    void consider(double v) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }

    if (mode == ChartMode.magnitude) {
      for (var i = 0; i < n; i++) {
        consider(buffer.magnitudeAt(i));
      }
    } else {
      for (var i = 0; i < n; i++) {
        consider(buffer.xs[i]);
        consider(buffer.ys[i]);
        consider(buffer.zs[i]);
      }
    }
    var span = hi - lo;
    if (span < 1.0) span = 1.0; // avoid amplifying noise into a full-height wobble
    lo -= span * 0.05;
    hi += span * 0.05;
    span = hi - lo;

    double mapY(double v) =>
        size.height - ((v - lo) / span) * size.height;
    double mapX(int i) => (i / (n - 1)) * size.width;

    Path line(double Function(int) value) {
      final p = Path()..moveTo(mapX(0), mapY(value(0)));
      for (var i = 1; i < n; i++) {
        p.lineTo(mapX(i), mapY(value(i)));
      }
      return p;
    }

    final stroke = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    if (mode == ChartMode.magnitude) {
      canvas.drawPath(
          line(buffer.magnitudeAt), stroke..color = x);
    } else {
      canvas.drawPath(line((i) => buffer.xs[i]), stroke..color = x);
      canvas.drawPath(line((i) => buffer.ys[i]), stroke..color = y);
      canvas.drawPath(line((i) => buffer.zs[i]), stroke..color = z);
    }

    // Range labels.
    _label(canvas, size, '${lo.toStringAsFixed(1)} … ${hi.toStringAsFixed(1)} m/s²',
        alignBottom: true);
    if (mode == ChartMode.axes) {
      _legend(canvas, size);
    }
  }

  void _label(Canvas canvas, Size size, String s, {bool alignBottom = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: text, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(6, alignBottom ? size.height - tp.height - 4 : 4));
  }

  void _legend(Canvas canvas, Size size) {
    final items = [('X', x), ('Y', y), ('Z', z)];
    var dx = 6.0;
    for (final (label, color) in items) {
      final tp = TextPainter(
        text: TextSpan(
            text: label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(dx, 4));
      dx += tp.width + 12;
    }
  }

  @override
  bool shouldRepaint(covariant _LiveChartPainter old) => true;
}
