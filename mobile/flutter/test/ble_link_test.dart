import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liftosaur_garmin/ble_link.dart';
import 'package:liftosaur_garmin/binary_frames.dart';
import 'package:liftosaur_garmin/protocol.dart';

/// The BLE link's decoding core, tested without any Bluetooth plugin. This is
/// the part that would silently corrupt a set if wrong, so it is exercised
/// directly: fragments in, decoded frames out.
void main() {
  LiftFrame chunk(int seq, {int samples = 20}) => LiftFrame(
        version: liftProtocolVersion,
        type: FrameType.chunk,
        seq: seq,
        timestampMs: 1724865600123,
        exerciseId: 1,
        rateHz: 20,
        flags: 0,
        scale: 1000,
        channels: const ['x', 'y', 'z'],
        samples: [
          for (var i = 0; i < samples; i++) [i - 10, 9810 + i, -i],
        ],
      );

  test('watch UUIDs match the Monkey C transport', () {
    // These strings are the contract with LiftBleTransport.mc — if either side
    // changes, the watch silently never connects.
    expect(kLiftServiceUuid, '4c494654-0001-4000-8000-00805f9b34fb');
    expect(kLiftDataUuid, '4c494654-0002-4000-8000-00805f9b34fb');
  });

  test('reassembles a fragmented chunk into a decoded frame', () {
    final assembler = FrameAssembler();
    final bytes = encodeFrame(chunk(7));
    final frags = const FrameFragmenter(payloadBytes: 20).split(bytes);

    LiftFrame? got;
    for (final f in frags) {
      got = assembler.add(f) ?? got;
    }

    expect(got, isNotNull);
    expect(got!.seq, 7);
    expect(got.rateHz, 20);
    expect(got.samples, hasLength(20));
    expect(got.channels, ['x', 'y', 'z']);
    expect(assembler.framesDecoded, 1);
    expect(assembler.decodeErrors, 0);
    expect(assembler.fragmentsReceived, frags.length);
  });

  test('a single-fragment frame needs no second write', () {
    final assembler = FrameAssembler();
    final bytes = encodeFrame(chunk(1));
    final f = assembler.add(const FrameFragmenter(payloadBytes: 180).split(bytes).single);
    expect(f, isNotNull);
    expect(f!.type, FrameType.chunk);
  });

  test('handles a stream of consecutive frames without losing one', () {
    final assembler = FrameAssembler();
    const fr = FrameFragmenter(payloadBytes: 60);
    final decoded = <int>[];
    for (var seq = 1; seq <= 5; seq++) {
      for (final frag in fr.split(encodeFrame(chunk(seq)))) {
        final f = assembler.add(frag);
        if (f != null) decoded.add(f.seq);
      }
    }
    expect(decoded, [1, 2, 3, 4, 5]);
    expect(assembler.framesDecoded, 5);
  });

  test('counts a corrupt frame instead of throwing', () {
    final assembler = FrameAssembler();
    // A complete, length-consistent fragment whose payload is not a valid frame.
    final junk = Uint8List(8);
    ByteData.view(junk.buffer).setUint16(0, 4, Endian.little);
    junk[2] = 0;
    junk[3] = 1;
    junk.setRange(4, 8, [0xde, 0xad, 0xbe, 0xef]);

    expect(assembler.add(junk), isNull);
    expect(assembler.decodeErrors, 1);
    expect(assembler.lastErrors, isNotEmpty);

    // ...and the assembler still works afterwards.
    final bytes = encodeFrame(chunk(9));
    final f = assembler.add(const FrameFragmenter(payloadBytes: 180).split(bytes).single);
    expect(f?.seq, 9);
  });

  test('a protocol-version mismatch is counted separately', () {
    final assembler = FrameAssembler();
    final bytes = Uint8List.fromList(encodeFrame(chunk(1)))..[2] = 99;
    assembler.add(const FrameFragmenter(payloadBytes: 180).split(bytes).single);
    expect(assembler.versionMismatches, 1);
    expect(assembler.framesDecoded, 0);
  });

  test('summary reports the counters the UI needs', () {
    final a = FrameAssembler();
    final bytes = encodeFrame(chunk(1));
    a.add(const FrameFragmenter(payloadBytes: 180).split(bytes).single);
    expect(a.summary(), contains('frames=1'));
    expect(a.summary(), contains('frags=1'));
  });
}
