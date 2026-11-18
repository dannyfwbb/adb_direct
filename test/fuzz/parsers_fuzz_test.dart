// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Feeds malformed input to every parser of bytes that come from outside (the network, a device, a file) and checks
// that each one either succeeds or fails with its documented error: never a RangeError, a StateError or a hang.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/compression/lz4.dart';
import 'package:adb_direct/src/crypto/der.dart';
import 'package:adb_direct/src/discovery/dns_message.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/protocol/shell_protocol.dart';
import 'package:adb_direct/src/services/answers.dart';
import 'package:adb_direct/src/services/debug.dart' show BugreportLine, decodeAppProcesses;
import 'package:adb_direct/src/services/incremental.dart' show apkPriorityBlocks, parseIdsig;
import 'package:adb_direct/src/services/packages.dart' show parsePackageList, pmFailure, pmSessionId;
import 'package:adb_direct/src/services/properties.dart' show parseGetprop;
import 'package:test/test.dart';

final int rounds = int.parse(Platform.environment['FUZZ_ROUNDS'] ?? '3000');

/// A mutation of [seed]: bits flipped, bytes changed, cut, extended or spliced, or random bytes.
Uint8List mutate(Random random, List<int> seed) {
  final bytes = List<int>.of(seed);
  final steps = 1 + random.nextInt(4);
  for (var s = 0; s < steps; s++) {
    switch (random.nextInt(7)) {
      case 0 when bytes.isNotEmpty:
        final i = random.nextInt(bytes.length);
        bytes[i] ^= 1 << random.nextInt(8);
      case 1 when bytes.isNotEmpty:
        bytes[random.nextInt(bytes.length)] = [0, 0xff, 0x7f, 0x80, random.nextInt(256)][random.nextInt(5)];
      case 2 when bytes.isNotEmpty:
        bytes.length = random.nextInt(bytes.length);
      case 3:
        bytes.insertAll(
          random.nextInt(bytes.length + 1),
          List.generate(random.nextInt(16), (_) => random.nextInt(256)),
        );
      case 4 when bytes.length > 4:
        // A 32-bit field set to an extreme.
        final i = random.nextInt(bytes.length - 3);
        final value = [0xffffffff, 0x7fffffff, 0x80000000, 0, 1][random.nextInt(5)];
        for (var k = 0; k < 4; k++) {
          bytes[i + k] = (value >> (8 * k)) & 0xff;
        }
      case 5 when bytes.length > 2:
        final from = random.nextInt(bytes.length);
        final to = random.nextInt(bytes.length);
        bytes.insertAll(to, bytes.sublist(from, min(bytes.length, from + random.nextInt(32))));
      default:
        bytes
          ..clear()
          ..addAll(List.generate(random.nextInt(64), (_) => random.nextInt(256)));
    }
  }
  return Uint8List.fromList(bytes);
}

/// Runs [parse] on [rounds] mutations of [seeds]; only [allowed] errors may come out.
void fuzz(String name, List<List<int>> seeds, void Function(Uint8List input) parse, {required List<Type> allowed}) {
  test(name, () {
    final random = Random(name.hashCode);
    for (var i = 0; i < rounds; i++) {
      final input = mutate(random, seeds[random.nextInt(seeds.length)]);
      try {
        parse(input);
      } on Object catch (e) {
        final ok = allowed.any(
          (type) => switch (type) {
            const (FormatException) => e is FormatException,
            const (AdbException) => e is AdbException,
            _ => false,
          },
        );
        if (!ok) fail('$name threw ${e.runtimeType}: $e\ninput (${input.length} B): ${input.take(200).toList()}');
      }
    }
  });
}

String text(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

void main() {
  final apk = File('test/fixtures/apks/app-v1.apk').readAsBytesSync();
  final idsig = File('test/fixtures/apks/app-v1.apk.idsig').readAsBytesSync();
  final lz4Frame = File('test/fixtures/sync/lz4_pull.bin').readAsBytesSync().sublist(0, 3000);
  final mdns = File('test/fixtures/mdns/avahi_legacy_answer.bin').readAsBytesSync();
  final trackApp = File('test/fixtures/services/track_app_tv.bin').readAsBytesSync();
  final pem = File('test/fixtures/keys/adbkey').readAsStringSync();
  final pub = File('test/fixtures/keys/adbkey.pub').readAsStringSync();

  fuzz('DNS messages', [mdns], DnsMessage.decode, allowed: [FormatException]);

  fuzz(
    'ADB message reader',
    [
      AdbMessageCodec.encode(AdbMessage.write(localId: 1, remoteId: 2, data: [1, 2, 3]), withChecksum: true),
      AdbMessageCodec.encode(AdbMessage.connect(banner: 'device::features=a'), withChecksum: false),
    ],
    (input) {
      final reader = AdbMessageReader()..add(input);
      reader.drain().toList();
    },
    allowed: [AdbException],
  );

  fuzz('banners', [utf8.encode('device::ro.product.name=p;ro.product.model=M;features=shell_v2,cmd')], (input) {
    AdbBanner.parse(input);
  }, allowed: []);

  fuzz(
    'shell protocol packets',
    [
      ShellProtocol.encode(ShellPacketId.stdout, [1, 2, 3]),
    ],
    (input) {
      (ShellPacketReader()..add(input)).drain().toList();
    },
    allowed: [AdbException],
  );

  fuzz('smart socket answers', [ascii.encode('OKAY000542277'), ascii.encode('FAIL0003bad'), ascii.encode('OKAY')], (
    input,
  ) {
    SmartAnswer.parse(input);
  }, allowed: [AdbException]);

  fuzz('track-app protobuf', [trackApp], decodeAppProcesses, allowed: [AdbException]);

  fuzz('DER', [base64.decode(pem.split('\n').where((l) => !l.startsWith('-----')).join())], (input) {
    DerElement.parse(input);
  }, allowed: [FormatException]);

  fuzz('PEM private keys', [utf8.encode(pem)], (input) => AdbKeyPair.fromPem(text(input)), allowed: [FormatException]);

  fuzz('adbkey.pub lines', [utf8.encode(pub)], (input) => AdbPublicKey.parse(text(input)), allowed: [FormatException]);

  fuzz('LZ4 frames', [lz4Frame, Lz4Frame.encoder.convert(utf8.encode('hello hello hello hello'))], (input) {
    Lz4Frame.decoder.convert(input);
  }, allowed: [FormatException]);

  fuzz('LZ4 blocks', [Lz4.compressBlock(utf8.encode('abcabcabcabcabcabc and more text text text'))], (input) {
    Lz4.decompressBlock(input, Uint8List(4096));
  }, allowed: [FormatException]);

  fuzz('.idsig files', [idsig.sublist(0, 1600)], (input) => parseIdsig(input, apk.length), allowed: [FormatException]);

  test('APK priority blocks never throw past the file', () async {
    final random = Random(5);
    for (var i = 0; i < 400; i++) {
      final input = mutate(random, apk);
      Future<Uint8List> read(int offset, int length) async {
        if (offset < 0 || length < 0 || offset + length > input.length) {
          throw RangeError('read($offset, $length) of ${input.length} bytes');
        }
        return Uint8List.sublistView(input, offset, offset + length);
      }

      final blocks = await apkPriorityBlocks(read, input.length);
      for (final b in blocks) {
        expect(b * 4096, lessThan(input.length));
      }
    }
  });

  fuzz(
    'text parsers (getprop, pm, bug report, server device lines)',
    [
      utf8.encode('[a]: [b]\n[c]: [d\ne]\n'),
      utf8.encode('package:/data/app/x==/base.apk=a.b versionCode:3  installer=null uid:10091,1010091\n'),
      utf8.encode('PROGRESS:5/10\nOK:/x\nFAIL:y'),
      utf8.encode('Success: created install session [123]\nFailure [INSTALL_FAILED_X: y]'),
      utf8.encode('emulator-5554 device product:x model:y transport_id:3\nserial no permissions (x) usb:1'),
    ],
    (input) {
      final s = text(input);
      parseGetprop(s);
      parsePackageList(s);
      pmFailure(s, 'x');
      pmSessionId(s);
      for (final line in s.split('\n')) {
        BugreportLine.parse(line);
        AdbService.parseInstance(line);
        try {
          AdbServerDevice.parse(line);
        } on AdbProtocolException {
          // A line too short to be a device.
        }
      }
    },
    allowed: [],
  );

  test('lengths near 2^63 cannot overflow a bounds check', () {
    // Field 1, length-delimited, length 2^63 - 1.
    final huge = Uint8List.fromList([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 1, 2]);
    expect(() => decodeAppProcesses(huge), throwsA(isA<AdbProtocolException>()));
    // An 11-byte varint.
    expect(
      () => decodeAppProcesses(Uint8List.fromList([0x08, ...List.filled(10, 0xff), 0x01])),
      throwsA(isA<AdbProtocolException>()),
    );
    expect(
      () => DerElement.parse([0x30, 0x88, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]),
      throwsFormatException,
    );
  });

  test('LZ4: what we encode decodes to the same bytes, for data shaped to stress the matcher', () {
    final random = Random(11);
    Uint8List shaped(int n) {
      final kind = random.nextInt(5);
      final out = Uint8List(n);
      for (var i = 0; i < n; i++) {
        out[i] = switch (kind) {
          0 => random.nextInt(256),
          1 => random.nextInt(3),
          2 =>
            i < 8
                ? random.nextInt(256)
                : (random.nextInt(50) == 0 ? random.nextInt(256) : out[i - 1 - random.nextInt(8)]),
          3 => (i ~/ (1 + random.nextInt(300))) & 0xff,
          _ => i % 70000 < 66000 ? 7 : random.nextInt(256),
        };
      }
      return out;
    }

    for (var round = 0; round < rounds ~/ 30 + 20; round++) {
      final n = [0, 1, 11, 12, 13, 17, 65535, 65536, 65537, 140000][random.nextInt(10)] + random.nextInt(40);
      final data = shaped(n);
      final block = Lz4.compressBlock(data);
      final out = Uint8List(n);
      expect(Lz4.decompressBlock(block, out), n);
      expect(out, data);
      // Chunked through the frame encoder and decoder, in random pieces.
      final encoded = BytesBuilder();
      final encoder = Lz4Frame.encoder.startChunkedConversion(_Collect(encoded));
      for (var i = 0; i < n;) {
        final end = min(n, i + 1 + random.nextInt(30000));
        encoder.add(data.sublist(i, end));
        i = end;
      }
      encoder.close();
      expect(Lz4Frame.decoder.convert(encoded.takeBytes()), data);
    }
  });
}

final class _Collect implements Sink<List<int>> {
  _Collect(this.builder);
  final BytesBuilder builder;
  @override
  void add(List<int> data) => builder.add(data);
  @override
  void close() {}
}
