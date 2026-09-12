/// In-app event log.
///
/// This exists because of a real dead end: the watch writes diagnostics with
/// `System.println`, which only reaches the Connect IQ developer console — never
/// `CIQ_LOG.YML` (that file only records crashes). So while the watch screen was
/// showing "sent=0 / fail=0", there was nothing anywhere to say *why*. Anything
/// the phone observes now lands here instead.
library;

import 'package:flutter/foundation.dart';

class LogEntry {
  final DateTime at;
  final String tag;
  final String message;

  LogEntry(this.tag, this.message) : at = DateTime.now();

  /// `HH:MM:SS.mmm  tag  message`
  String get line {
    final t = at;
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '.${t.millisecond.toString().padLeft(3, '0')}';
    return '$stamp  ${tag.padRight(7)} $message';
  }

  @override
  String toString() => line;
}

/// Bounded, observable log.
class DebugLog extends ChangeNotifier {
  final int capacity;
  final List<LogEntry> entries = [];

  /// Counts per tag, so the UI can show e.g. "frag 128 / frame 6 / err 0".
  final Map<String, int> counts = {};

  DebugLog({this.capacity = 500});

  void add(String tag, String message) {
    entries.add(LogEntry(tag, message));
    counts[tag] = (counts[tag] ?? 0) + 1;
    if (entries.length > capacity) {
      entries.removeRange(0, entries.length - capacity);
    }
    notifyListeners();
  }

  void addError(String tag, Object error) => add(tag, 'ERROR $error');

  /// Newest first — what a debug pane should show.
  List<LogEntry> get newestFirst => entries.reversed.toList(growable: false);

  /// Everything, oldest first — for copy/paste into a report.
  String dump() => entries.map((e) => e.line).join('\n');

  void clear() {
    entries.clear();
    counts.clear();
    notifyListeners();
  }
}
