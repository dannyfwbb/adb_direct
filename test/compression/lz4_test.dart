// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/src/compression/lz4.dart';
import 'package:adb_direct/src/compression/xxhash32.dart';
import 'package:test/test.dart';

/// The text the device compressed in `test/fixtures/sync/lz4_pull.bin`.
Uint8List sample() =>
    utf8.encode([for (var i = 0; i < 4000; i++) 'line $i: ${'abcdefghij' * (i % 7)} ${i * i % 9973}\n'].join());

/// Feeds [input] to a chunked [converter] in pieces of [piece] bytes.
Uint8List chunked(Converter<List<int>, List<int>> converter, List<int> input, int piece) {
  final output = BytesBuilder();
  final sink = converter.startChunkedConversion(_Sink(output));
  for (var i = 0; i < input.length; i += piece) {
    sink.add(input.sublist(i, min(i + piece, input.length)));
  }
  sink.close();
  return output.takeBytes();
}

final class _Sink implements Sink<List<int>> {
  _Sink(this.builder);
  final BytesBuilder builder;
  @override
  void add(List<int> data) => builder.add(data);
  @override
  void close() {}
}

Uint8List le32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

/// A frame header with [flags] and [bd], its checksum computed.
List<int> header(int flags, int bd, [List<int> extra = const []]) {
  final descriptor = [flags, bd, ...extra];
  return [...le32(Lz4Frame.magic), ...descriptor, (Xxh32.of(descriptor) >> 8) & 0xff];
}

void main() {
  group('XXH32', () {
    test('reference values from the xxHash documentation', () {
      expect(Xxh32.of([]), 0x02cc5d05);
      expect(Xxh32.of(utf8.encode('abc')), 0x32d153ff);
      expect(Xxh32.of(utf8.encode('Nobody inspects the spammish repetition')), 0xe2293b2f);
    });

    test('fed in pieces equals in one go, across stripes', () {
      final data = List.generate(1000, (i) => i * 7 & 0xff);
      final pieces = Xxh32();
      for (var i = 0; i < data.length; i += 13) {
        pieces.add(data, i, min(i + 13, data.length));
      }
      expect(pieces.digest(), Xxh32.of(data));
      expect(Xxh32.of(data, 1), isNot(Xxh32.of(data)));
    });
  });

  group('LZ4 blocks', () {
    test('round trips, sizes around the format limits', () {
      final random = Random(7);
      for (final n in [0, 1, 4, 5, 12, 13, 14, 15, 16, 19, 20, 270, 4096, 70000]) {
        for (final kind in ['zeros', 'text', 'random']) {
          final data = Uint8List.fromList(
            List.generate(
              n,
              (i) => switch (kind) {
                'zeros' => 0,
                'text' => 'abcabcabd'.codeUnitAt(i % 9),
                _ => random.nextInt(256),
              },
            ),
          );
          final block = Lz4.compressBlock(data);
          expect(block.length, lessThanOrEqualTo(Lz4.compressBound(n)));
          final out = Uint8List(n);
          expect(Lz4.decompressBlock(block, out), n, reason: '$kind $n');
          expect(out, data, reason: '$kind $n');
          if (kind == 'zeros' && n >= 4096) expect(block.length, lessThan(n ~/ 50));
        }
      }
    });

    test('long literal and match lengths use the 255-continuation bytes', () {
      final data = Uint8List.fromList([
        ...List.generate(600, (i) => (i * 37 + i ~/ 3) & 0xff),
        ...List.filled(5000, 9),
      ]);
      final block = Lz4.compressBlock(data);
      final out = Uint8List(data.length);
      Lz4.decompressBlock(block, out);
      expect(out, data);
    });

    test('malformed blocks: offset 0, offset before the data, truncation, output too small', () {
      // Token: 1 literal, match of 4; literal 'a'; offset.
      expect(() => Lz4.decompressBlock([0x10, 0x61, 0, 0, 0x00], Uint8List(10)), throwsFormatException);
      expect(() => Lz4.decompressBlock([0x10, 0x61, 2, 0, 0x00], Uint8List(10)), throwsFormatException);
      expect(() => Lz4.decompressBlock([0x30, 0x61], Uint8List(10)), throwsFormatException);
      expect(() => Lz4.decompressBlock([0x10, 0x61, 1], Uint8List(10)), throwsFormatException);
      expect(() => Lz4.decompressBlock([0x10, 0x61, 1, 0, 0x00], Uint8List(3)), throwsFormatException);
      expect(() => Lz4.decompressBlock([0xf0], Uint8List(10)), throwsFormatException);
      expect(() => Lz4.decompressBlock([], Uint8List(10)), throwsFormatException);
      // A valid overlapping match: 'a' then 4 more 'a' at offset 1, then 5 literals.
      final out = Uint8List(10);
      expect(Lz4.decompressBlock([0x10, 0x61, 1, 0, 0x50, ...'bcdef'.codeUnits], out), 10);
      expect(ascii.decode(out), 'aaaaabcdef');
    });

    test('matches may reach into the history before the block', () {
      final out = Uint8List(8)..setRange(0, 4, 'wxyz'.codeUnits);
      // No literals, a match of 4 at offset 4.
      expect(Lz4.decompressBlock([0x00, 4, 0, 0x00], out, outputStart: 4), 8);
      expect(ascii.decode(out), 'wxyzwxyz');
      expect(
        () => Lz4.decompressBlock([0x00, 4, 0, 0x00], out, outputStart: 4, historyStart: 4),
        throwsFormatException,
      );
    });
  });

  group('LZ4 frames', () {
    test('a frame recorded from adbd (linked 64 KiB blocks) decodes, whole and byte by byte', () {
      final frame = File('test/fixtures/sync/lz4_pull.bin').readAsBytesSync();
      expect(frame[4], 0x40, reason: 'linked blocks, no checksums');
      expect(Lz4Frame.decoder.convert(frame), sample());
      expect(chunked(Lz4Frame.decoder, frame, 1), sample());
      expect(chunked(Lz4Frame.decoder, frame, 4999), sample());
    });

    test('our frames: independent blocks and a content checksum; decode in any split', () {
      final data = sample();
      final frame = Lz4Frame.encoder.convert(data);
      expect(frame.sublist(0, 4), le32(Lz4Frame.magic));
      expect(frame[4], 0x64);
      expect(frame.length, lessThan(data.length ~/ 2));
      expect(Lz4Frame.decoder.convert(frame), data);
      expect(chunked(Lz4Frame.decoder, chunked(Lz4Frame.encoder, data, 1000), 333), data);
      expect(Lz4Frame.decoder.convert(Lz4Frame.encoder.convert([])), isEmpty);
    });

    test('incompressible blocks are stored', () {
      final random = Random(3);
      final data = List.generate(100000, (_) => random.nextInt(256));
      final frame = Lz4Frame.encoder.convert(data);
      expect(ByteData.sublistView(Uint8List.fromList(frame), 7, 11).getUint32(0, Endian.little), 0x80000000 | 65536);
      expect(Lz4Frame.decoder.convert(frame), data);
    });

    test('block checksums, content size, skippable and concatenated frames', () {
      final block = Lz4.compressBlock('hello hello hello hello'.codeUnits);
      final withChecks = [
        // Independent, block checksum, content size, content checksum; 64 KiB blocks.
        ...header(0x7c, 0x40, le32(23) + le32(0)),
        ...le32(block.length), ...block, ...le32(Xxh32.of(block)),
        ...le32(0), ...le32(Xxh32.of('hello hello hello hello'.codeUnits)),
      ];
      final skippable = [...le32(0x184d2a53), ...le32(3), 1, 2, 3];
      final stored = [...header(0x60, 0x70), ...le32(0x80000002), 0x21, 0x21, ...le32(0)];
      expect(
        ascii.decode(Lz4Frame.decoder.convert([...skippable, ...withChecks, ...stored])),
        'hello hello hello hello!!',
      );

      final badBlockSum = [...withChecks]..[19 + block.length] ^= 1;
      expect(() => Lz4Frame.decoder.convert(badBlockSum), throwsFormatException);
      final badContentSum = [...withChecks]..[withChecks.length - 1] ^= 1;
      expect(() => Lz4Frame.decoder.convert(badContentSum), throwsFormatException);
      final badSize = [...header(0x68, 0x40, le32(5) + le32(0)), ...le32(0x80000002), 0x21, 0x21, ...le32(0)];
      expect(() => Lz4Frame.decoder.convert(badSize), throwsFormatException);
    });

    test('malformed frames', () {
      expect(() => Lz4Frame.decoder.convert([1, 2, 3, 4, 5, 6, 7, 8]), throwsFormatException);
      final good = Lz4Frame.encoder.convert('abc'.codeUnits);
      expect(() => Lz4Frame.decoder.convert(good.sublist(0, good.length - 1)), throwsFormatException);
      expect(() => Lz4Frame.decoder.convert([...good]..[6] ^= 1), throwsFormatException, reason: 'header checksum');
      expect(() => Lz4Frame.decoder.convert(header(0x80, 0x40)), throwsFormatException, reason: 'version');
      expect(() => Lz4Frame.decoder.convert(header(0x61, 0x40, le32(1))), throwsFormatException, reason: 'dictionary');
      expect(() => Lz4Frame.decoder.convert(header(0x60, 0x30)), throwsFormatException, reason: 'block size');
      expect(
        () => Lz4Frame.decoder.convert([...header(0x60, 0x40), ...le32(70000), ...List.filled(70000, 0)]),
        throwsFormatException,
        reason: 'block past the maximum',
      );
    });
  });
}
