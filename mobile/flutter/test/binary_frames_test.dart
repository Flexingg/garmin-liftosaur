import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/binary_frames.dart';
import 'package:liftosaur_garmin/protocol.dart';

/// The golden vectors below were computed independently from the docs/01 spec
/// (little-endian throughout), NOT from this package's encoder — so they pin
/// the wire format rather than just asserting the code agrees with itself.
/// A change here is a breaking protocol change, not a test to update casually.
const String kChunkGoldenHex =
    '46 4c 01 01 9c 01 00 00 7b 5a 00 9a 91 01 00 00 03 00 14 00 00 00 00 00 '
    '02 00 07 e8 03 88 ff d4 03 d4 ff 00 00 f2 03 c4 ff';

const String kSetEndGoldenHex =
    '46 4c 01 02 9d 01 00 00 cb a0 00 9a 91 01 00 00 03 00 14 01 00 00 00 00 '
    '50 46 00 00 00';

Uint8List hexToBytes(String hex) {
  final parts = hex.trim().split(RegExp(r'\s+'));
  return Uint8List.fromList([for (final p in parts) int.parse(p, radix: 16)]);
}

String bytesToHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

LiftFrame sampleChunk() => LiftFrame(
      version: liftProtocolVersion,
      type: FrameType.chunk,
      seq: 412,
      timestampMs: 1724865600123,
      exerciseId: 3,
      rateHz: 20,
      flags: 0,
      scale: 1000,
      channels: const ['x', 'y', 'z'],
      samples: const [
        [-120, 980, -44],
        [0, 1010, -60],
      ],
    );

void main() {
  group('binary frame layout (docs/01 §2-§3) — golden vectors', () {
    test('chunk frame encodes to the exact contract bytes', () {
      final got = encodeFrame(sampleChunk());
      expect(bytesToHex(got), kChunkGoldenHex.replaceAll(' ', ' '));
      expect(got.length, headerBytes + 5 + 2 * 3 * 2); // 24 + 5 + 12
    });

    test('set_end frame encodes to the exact contract bytes', () {
      final f = LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.setEnd,
        seq: 413,
        timestampMs: 1724865618123,
        exerciseId: 3,
        rateHz: 20,
        flags: flagChunkEnd,
        scale: 1000,
        channels: const ['x', 'y', 'z'],
        samples: const [],
        durationMs: 18000,
        repHint: 0,
      );
      expect(bytesToHex(encodeFrame(f)), kSetEndGoldenHex);
    });

    test('golden chunk decodes back to the same field values', () {
      final f = decodeFrame(hexToBytes(kChunkGoldenHex));
      expect(f.type, FrameType.chunk);
      expect(f.seq, 412);
      expect(f.timestampMs, 1724865600123);
      expect(f.exerciseId, 3);
      expect(f.rateHz, 20);
      expect(f.scale, 1000);
      expect(f.channels, ['x', 'y', 'z']);
      expect(f.samples, [
        [-120, 980, -44],
        [0, 1010, -60],
      ]);
    });

    test('round-trips a 1-second chunk at the real watch rate', () {
      final rows = [
        for (var i = 0; i < 20; i++) [i * 3 - 30, 9810 + i, -i * 5],
      ];
      final f = LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.chunk,
        seq: 7,
        timestampMs: 1000000,
        exerciseId: 1,
        rateHz: 20,
        flags: 0,
        scale: 1000,
        channels: const ['x', 'y', 'z'],
        samples: rows,
      );
      final bytes = encodeFrame(f);
      expect(bytes.length, headerBytes + 5 + 20 * 3 * 2); // 144 bytes
      final back = decodeFrame(bytes);
      expect(back.samples, rows);
      expect(back.rateHz, 20);
    });
  });

  group('decodeFrame error handling', () {
    test('rejects bad magic, bad version, bad type, truncation', () {
      final good = encodeFrame(sampleChunk());

      final badMagic = Uint8List.fromList(good)..[0] = 0x00;
      expect(() => decodeFrame(badMagic), throwsFormatException);

      final badVersion = Uint8List.fromList(good)..[2] = 9;
      expect(() => decodeFrame(badVersion), throwsFormatException);

      final badType = Uint8List.fromList(good)..[3] = 99;
      expect(() => decodeFrame(badType), throwsFormatException);

      expect(() => decodeFrame(good.sublist(0, 10)), throwsFormatException);
      expect(() => decodeFrame(good.sublist(0, headerBytes + 3)),
          throwsFormatException);
    });

    test('a chunk claiming more samples than present is rejected', () {
      final good = encodeFrame(sampleChunk());
      final lying = Uint8List.fromList(good);
      ByteData.view(lying.buffer).setUint16(headerBytes, 999, Endian.little);
      expect(() => decodeFrame(lying), throwsFormatException);
    });
  });

  group('FrameFragmenter / FrameReassembler', () {
    test('a 144-byte frame survives fragmentation and reassembly', () {
      final bytes = encodeFrame(sampleChunk());
      final frag = const FrameFragmenter(payloadBytes: 20).split(bytes);
      expect(frag.length, greaterThan(1)); // forces real fragmentation

      final r = FrameReassembler();
      Uint8List? out;
      for (final f in frag) {
        out = r.add(f) ?? out;
      }
      expect(out, isNotNull);
      expect(out, bytes);
      expect(decodeFrame(out!).seq, 412);
    });

    test('a frame that fits in one fragment still carries the header', () {
      final bytes = encodeFrame(sampleChunk());
      final frag = const FrameFragmenter(payloadBytes: 180).split(bytes);
      expect(frag, hasLength(1));
      final r = FrameReassembler();
      expect(r.add(frag.single), bytes);
    });

    test('duplicate fragments are ignored, not spliced', () {
      final bytes = encodeFrame(sampleChunk());
      final frag = const FrameFragmenter(payloadBytes: 20).split(bytes);
      final r = FrameReassembler();
      expect(r.add(frag[0]), isNull);
      expect(r.add(frag[0]), isNull); // duplicate of fragment 0
      expect(r.duplicateFragments, 1);
      Uint8List? out;
      for (final f in frag.sublist(1)) {
        out = r.add(f) ?? out;
      }
      expect(out, bytes);
    });

    test('an abandoned frame is dropped instead of mixed with the next', () {
      final a = encodeFrame(sampleChunk());
      final b = encodeFrame(LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.chunk,
        seq: 999,
        timestampMs: 5,
        exerciseId: 1,
        rateHz: 20,
        flags: 0,
        scale: 1000,
        channels: const ['x', 'y', 'z'],
        samples: const [
          [1, 2, 3],
        ],
      ));
      const fr = FrameFragmenter(payloadBytes: 20);
      final ra = fr.split(a);
      final rb = fr.split(b);
      final r = FrameReassembler();

      expect(r.add(ra[0]), isNull); // start frame A, never finish it
      Uint8List? out;
      for (final f in rb) {
        out = r.add(f) ?? out;
      }
      expect(r.incompleteDrops, 1);
      expect(out, isNotNull);
      expect(decodeFrame(out!).seq, 999);
    });

    test('rejects malformed fragments without wedging', () {
      final r = FrameReassembler();
      expect(r.add(Uint8List.fromList([1, 2])), isNull);
      expect(r.badFragments, 1);
      // index >= count
      expect(r.add(Uint8List.fromList([4, 0, 5, 2, 9])), isNull);
      expect(r.badFragments, 2);
      // and it still works afterwards
      final bytes = encodeFrame(sampleChunk());
      expect(r.add(const FrameFragmenter(payloadBytes: 180).split(bytes).single),
          bytes);
    });
  });
}
