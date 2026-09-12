/// Compact binary wire format for watch -> phone frames (docs/01 §2–§3),
/// plus the fragment reassembler used over BLE.
///
/// Why binary and not the JSON dict form: at 20 Hz a one-second CHUNK is
/// 24 + 20*3*2 = 144 bytes binary, versus ~400 bytes of JSON. Over BLE that
/// matters, and docs/01 makes the binary form the BLE contract.
///
/// Role note: Garmin's Connect IQ BLE API is **central role only** — the watch
/// cannot advertise or host a GATT server. So the phone is the peripheral
/// (GATT server) and the watch is the central that writes to it. This file is
/// the receiving end.
library;

import 'dart:typed_data';

import 'protocol.dart';

/// "LF" — docs/01 §2 magic.
const int liftMagic = 0x4C46;

/// Fixed header length in bytes (docs/01 §2).
const int headerBytes = 24;

/// Fragment header: u16 total length, u8 index, u8 count.
const int fragmentHeaderBytes = 4;

/// A single GATTC write cannot carry an arbitrary payload, so each fragment
/// carries a tiny header letting the receiver reassemble. Payload size must be
/// chosen so `fragmentHeaderBytes + payload <= MTU - 3`.
class FrameFragmenter {
  final int payloadBytes;

  const FrameFragmenter({this.payloadBytes = 180});

  List<Uint8List> split(Uint8List frame) {
    if (frame.isEmpty) return const [];
    final count = (frame.length + payloadBytes - 1) ~/ payloadBytes;
    if (count > 255) {
      throw ArgumentError('frame of ${frame.length} bytes needs $count '
          'fragments; u8 fragment count would overflow');
    }
    if (frame.length > 0xFFFF) {
      throw ArgumentError('frame of ${frame.length} bytes exceeds u16 length field');
    }
    final out = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * payloadBytes;
      final end = (start + payloadBytes).clamp(0, frame.length);
      final chunk = frame.sublist(start, end);
      final buf = Uint8List(fragmentHeaderBytes + chunk.length);
      final bd = ByteData.view(buf.buffer);
      bd.setUint16(0, frame.length, Endian.little);
      buf[2] = i;
      buf[3] = count;
      buf.setRange(fragmentHeaderBytes, buf.length, chunk);
      out.add(buf);
    }
    return out;
  }
}

/// Reassembles fragments into whole frames.
///
/// Tolerant by design: BLE writes can arrive out of order or be retried, so a
/// stale/duplicate fragment must not corrupt the frame, and an abandoned frame
/// must not wedge the reassembler.
class FrameReassembler {
  final List<Uint8List?> _parts = [];
  int _expected = 0;
  int _totalLength = 0;
  int _received = 0;

  int incompleteDrops = 0;
  int duplicateFragments = 0;
  int badFragments = 0;

  /// Feed one fragment. Returns the complete frame, or null if still waiting.
  Uint8List? add(Uint8List fragment) {
    if (fragment.length < fragmentHeaderBytes) {
      badFragments++;
      return null;
    }
    final bd = ByteData.view(fragment.buffer, fragment.offsetInBytes);
    final totalLength = bd.getUint16(0, Endian.little);
    final index = fragment[2];
    final count = fragment[3];

    if (count == 0 || index >= count) {
      badFragments++;
      return null;
    }

    // A fragment for a *different* frame while one is in flight: drop the
    // partial frame rather than splicing two frames together.
    if (_expected != 0 && (count != _expected || totalLength != _totalLength)) {
      incompleteDrops++;
      _reset();
    }
    if (_expected == 0) {
      _expected = count;
      _totalLength = totalLength;
      _parts
        ..clear()
        ..addAll(List<Uint8List?>.filled(count, null));
      _received = 0;
    }

    final body = Uint8List.sublistView(fragment, fragmentHeaderBytes);
    if (_parts[index] != null) {
      duplicateFragments++;
      return null;
    }
    _parts[index] = Uint8List.fromList(body);
    _received++;

    if (_received < _expected) return null;

    // Capture the expected length BEFORE any reset: _reset() zeroes it, and
    // validating after the reset made every completed frame look truncated.
    final expectedLength = _totalLength;
    final out = Uint8List(expectedLength);
    var offset = 0;
    for (final p in _parts) {
      if (p == null) {
        // Shouldn't happen (counted _received), but never hand back garbage.
        incompleteDrops++;
        _reset();
        return null;
      }
      if (offset + p.length > expectedLength) {
        badFragments++;
        _reset();
        return null;
      }
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    if (offset != expectedLength) {
      badFragments++;
      _reset();
      return null;
    }
    _reset();
    return out;
  }

  void _reset() {
    _parts.clear();
    _expected = 0;
    _totalLength = 0;
    _received = 0;
  }
}

/// Encode a frame in the compact binary form (docs/01 §2, §3, §5).
Uint8List encodeFrame(LiftFrame f) {
  final isChunk = f.type == FrameType.chunk;
  final n = isChunk ? f.samples.length : 0;
  final channels = isChunk ? _channelCount(f.channels) : 0;
  final bodyBytes = switch (f.type) {
    FrameType.chunk => 5 + (n * channels * 2),
    FrameType.setEnd => 5,
    _ => 0,
  };

  final buf = Uint8List(headerBytes + bodyBytes);
  final bd = ByteData.view(buf.buffer);
  bd.setUint16(0, liftMagic, Endian.little);
  buf[2] = f.version;
  buf[3] = _typeCode(f.type);
  bd.setUint32(4, f.seq, Endian.little);
  bd.setInt64(8, f.timestampMs, Endian.little);
  bd.setUint16(16, f.exerciseId, Endian.little);
  buf[18] = f.rateHz & 0xFF;
  buf[19] = f.flags;
  bd.setUint32(20, 0, Endian.little); // reserved

  var o = headerBytes;
  switch (f.type) {
    case FrameType.chunk:
      bd.setUint16(o, n, Endian.little);
      buf[o + 2] = f.channelMaskFromChannels();
      bd.setInt16(o + 3, f.scale, Endian.little);
      o += 5;
      for (final row in f.samples) {
        for (final v in row) {
          bd.setInt16(o, v, Endian.little);
          o += 2;
        }
      }
    case FrameType.setEnd:
      bd.setUint32(o, f.durationMs ?? 0, Endian.little);
      buf[o + 4] = (f.repHint ?? 0) & 0xFF;
    default:
      break;
  }
  return buf;
}

/// Decode the compact binary form. Throws [FormatException] on bad magic,
/// unknown type, or a truncated body.
LiftFrame decodeFrame(Uint8List raw) {
  if (raw.length < headerBytes) {
    throw FormatException('frame shorter than header: ${raw.length} bytes');
  }
  final bd = ByteData.view(raw.buffer, raw.offsetInBytes);
  final magic = bd.getUint16(0, Endian.little);
  if (magic != liftMagic) {
    throw FormatException('bad magic 0x${magic.toRadixString(16)} '
        '(expected 0x${liftMagic.toRadixString(16)})');
  }
  final version = raw[2];
  if (version != liftProtocolVersion) {
    throw FormatException('protocol version $version != $liftProtocolVersion');
  }
  final type = _typeFromCode(raw[3]);
  final seq = bd.getUint32(4, Endian.little);
  final ts = bd.getInt64(8, Endian.little);
  final exerciseId = bd.getUint16(16, Endian.little);
  final rateHz = raw[18];
  final flags = raw[19];

  var samples = <List<int>>[];
  int scale = 1000;
  List<String> channels = const [];
  int? durationMs;
  int? repHint;

  if (type == FrameType.chunk) {
    if (raw.length < headerBytes + 5) {
      throw FormatException('chunk body truncated');
    }
    final n = bd.getUint16(headerBytes, Endian.little);
    final mask = raw[headerBytes + 2];
    scale = bd.getInt16(headerBytes + 3, Endian.little);
    final channelCount = _popcount(mask & 0x07);
    final needed = headerBytes + 5 + n * channelCount * 2;
    if (raw.length < needed) {
      throw FormatException(
          'chunk declares $n samples x $channelCount ch (need $needed bytes, got ${raw.length})');
    }
    channels = _channelsFor(mask);
    var o = headerBytes + 5;
    for (var i = 0; i < n; i++) {
      final row = <int>[];
      for (var c = 0; c < channelCount; c++) {
        row.add(bd.getInt16(o, Endian.little));
        o += 2;
      }
      samples.add(row);
    }
  } else if (type == FrameType.setEnd) {
    if (raw.length < headerBytes + 5) {
      throw FormatException('set_end body truncated');
    }
    durationMs = bd.getUint32(headerBytes, Endian.little);
    repHint = raw[headerBytes + 4];
  }

  return LiftFrame(
    version: version,
    type: type,
    seq: seq,
    timestampMs: ts,
    exerciseId: exerciseId,
    rateHz: rateHz,
    flags: flags,
    scale: scale,
    channels: channels,
    samples: samples,
    durationMs: durationMs,
    repHint: repHint,
  );
}

int _typeCode(FrameType t) => switch (t) {
      FrameType.hello => 0,
      FrameType.chunk => 1,
      FrameType.setEnd => 2,
      FrameType.cmd => 3,
      FrameType.unknown => 255,
    };

FrameType _typeFromCode(int code) => switch (code) {
      0 => FrameType.hello,
      1 => FrameType.chunk,
      2 => FrameType.setEnd,
      3 => FrameType.cmd,
      _ => throw FormatException('unknown frame type code $code'),
    };

int _popcount(int v) {
  var n = 0;
  while (v != 0) {
    n += v & 1;
    v >>= 1;
  }
  return n;
}

int _channelCount(List<String> channels) =>
    channels.isEmpty ? 3 : _popcount(_maskFor(channels));

int _maskFor(List<String> channels) {
  var mask = 0;
  for (final c in channels) {
    switch (c.toLowerCase().trim()) {
      case 'x':
        mask |= 0x01;
      case 'y':
        mask |= 0x02;
      case 'z':
        mask |= 0x04;
    }
  }
  return mask == 0 ? 0x07 : mask;
}

List<String> _channelsFor(int mask) => [
      if (mask & 0x01 != 0) 'x',
      if (mask & 0x02 != 0) 'y',
      if (mask & 0x04 != 0) 'z',
    ];

extension on LiftFrame {
  /// Channel mask implied by this frame's channel list (docs/01 §3).
  int channelMaskFromChannels() =>
      channels.isEmpty ? 0x07 : _maskFor(channels);
}
