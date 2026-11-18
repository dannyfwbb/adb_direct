// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_direct/src/errors.dart';
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('AdbCommand', () {
    test('wire values spell their names in little-endian ASCII', () {
      for (final command in AdbCommand.values) {
        final bytes = Uint8List(4)..buffer.asByteData().setUint32(0, command.value, Endian.little);
        expect(String.fromCharCodes(bytes), command.wireName);
      }
      expect(AdbCommand.connect.wireName, 'CNXN');
      expect(AdbCommand.close.wireName, 'CLSE');
    });

    test('fromValue', () {
      expect(AdbCommand.fromValue(0x45545257), AdbCommand.write);
      expect(AdbCommand.fromValue(0x12345678), isNull);
    });
  });

  group('AdbMessage', () {
    test('OPEN ends the service name with NUL', () {
      final message = AdbMessage.open(localId: 1, service: 'shell:id');
      expect(message.payload, [...utf8.encode('shell:id'), 0]);
      expect(message.arg1, 0);
    });

    test('OPEN carries the window when given', () {
      final message = AdbMessage.open(localId: 3, service: 'sync:', window: AdbProtocol.delayedAckWindow);
      expect(message.arg1, 0x2000000);
    });

    test('OKAY with an acknowledgement carries it as little-endian int32', () {
      final message = AdbMessage.okay(localId: 1, remoteId: 12, acknowledged: 3);
      expect(message.payload, [3, 0, 0, 0]);
      expect(message.acknowledgedBytes, 3);
      expect(AdbMessage.okay(localId: 1, remoteId: 2).acknowledgedBytes, isNull);
    });

    test('a negative acknowledgement survives the round trip', () {
      final message = AdbMessage.okay(localId: 1, remoteId: 2, acknowledged: -5);
      expect(message.acknowledgedBytes, -5);
    });

    test('an OKAY payload of another size is a protocol error', () {
      final message = AdbMessage(AdbCommand.okay, 1, 2, [1, 2]);
      expect(() => message.acknowledgedBytes, throwsA(isA<AdbProtocolException>()));
    });

    test('CLSE may refuse an OPEN with local id 0', () {
      final message = AdbMessage.close(localId: 0, remoteId: 5);
      expect((message.arg0, message.arg1), (0, 5));
    });

    test('stream ids must be non-zero 32-bit values', () {
      expect(() => AdbMessage.open(localId: 0, service: 'x'), throwsRangeError);
      expect(() => AdbMessage.write(localId: 1, remoteId: 0, data: const []), throwsRangeError);
      expect(() => AdbMessage(AdbCommand.okay, -1, 1), throwsRangeError);
      expect(() => AdbMessage(AdbCommand.okay, 0x100000000, 1), throwsRangeError);
    });

    test('payload is read-only and copied from plain lists', () {
      final source = [1, 2, 3];
      final message = AdbMessage(AdbCommand.write, 1, 2, source);
      source[0] = 9;
      expect(message.payload.first, 1);
      expect(() => message.payload[0] = 5, throwsUnsupportedError);
    });

    test('equality compares payload bytes', () {
      expect(
        AdbMessage(AdbCommand.write, 1, 2, [1, 2]),
        AdbMessage(AdbCommand.write, 1, 2, Uint8List.fromList([1, 2])),
      );
      expect(AdbMessage(AdbCommand.write, 1, 2, [1, 2]), isNot(AdbMessage(AdbCommand.write, 1, 2, [1, 3])));
    });
  });

  group('AdbMessageCodec', () {
    test('header layout', () {
      final bytes = AdbMessageCodec.encode(
        AdbMessage(AdbCommand.write, 0x01020304, 0x0a0b0c0d, [1, 2, 250]),
        withChecksum: true,
      );
      final header = ByteData.sublistView(bytes);
      expect(bytes.length, 27);
      expect(header.getUint32(0, Endian.little), AdbCommand.write.value);
      expect(header.getUint32(4, Endian.little), 0x01020304);
      expect(header.getUint32(8, Endian.little), 0x0a0b0c0d);
      expect(header.getUint32(12, Endian.little), 3);
      expect(header.getUint32(16, Endian.little), 253);
      expect(header.getUint32(20, Endian.little), AdbCommand.write.value ^ 0xffffffff);
      expect(bytes.sublist(24), [1, 2, 250]);
    });

    test('checksum is zero unless asked for', () {
      final bytes = AdbMessageCodec.encode(AdbMessage(AdbCommand.write, 1, 2, [9]), withChecksum: false);
      expect(ByteData.sublistView(bytes).getUint32(16, Endian.little), 0);
    });

    test('checksum wraps at 32 bits', () {
      expect(AdbMessageCodec.checksum(List.filled(5, 255)), 1275);
      expect(AdbMessageCodec.checksum(const []), 0);
    });
  });

  group('AdbMessageReader', () {
    Uint8List encode(AdbMessage message) => AdbMessageCodec.encode(message, withChecksum: false);

    test('returns null until a message is complete', () {
      final bytes = encode(AdbMessage(AdbCommand.write, 1, 2, [1, 2, 3]));
      final reader = AdbMessageReader()..add(bytes.sublist(0, 26));
      expect(reader.next(), isNull);
      reader.add(bytes.sublist(26));
      expect(reader.next(), AdbMessage(AdbCommand.write, 1, 2, [1, 2, 3]));
      expect(reader.next(), isNull);
    });

    test('splits several messages in one chunk', () {
      final reader = AdbMessageReader()
        ..add([
          ...encode(AdbMessage.okay(localId: 5, remoteId: 1)),
          ...encode(AdbMessage.close(localId: 5, remoteId: 1)),
        ]);
      expect(reader.next()!.command, AdbCommand.okay);
      expect(reader.next()!.command, AdbCommand.close);
      expect(reader.next(), isNull);
    });

    test('drain yields every complete message and keeps the rest', () {
      final second = encode(AdbMessage(AdbCommand.write, 5, 1, [1, 2]));
      final reader = AdbMessageReader()
        ..add([...encode(AdbMessage.okay(localId: 5, remoteId: 1)), ...second.sublist(0, 25)]);
      expect(reader.drain().map((m) => m.command), [AdbCommand.okay]);
      reader.add(second.sublist(25));
      expect(reader.drain(), [
        AdbMessage(AdbCommand.write, 5, 1, [1, 2]),
      ]);
    });

    test('ignores checksums, as adbd does', () {
      final bytes = encode(AdbMessage(AdbCommand.write, 1, 2, [1]));
      ByteData.sublistView(bytes).setUint32(16, 0xdeadbeef, Endian.little);
      expect((AdbMessageReader()..add(bytes)).next(), isNotNull);
    });

    test('rejects a bad magic', () {
      final bytes = encode(AdbMessage(AdbCommand.write, 1, 2));
      bytes[20] ^= 1;
      expect(() => (AdbMessageReader()..add(bytes)).next(), throwsA(isA<AdbProtocolException>()));
    });

    test('rejects a payload above the limit before it arrives', () {
      final bytes = encode(AdbMessage(AdbCommand.write, 1, 2, [1, 2, 3, 4, 5]));
      final reader = AdbMessageReader(maxPayload: 4)..add(bytes.sublist(0, 24));
      expect(reader.next, throwsA(isA<AdbProtocolException>()));
    });

    test('accepts a payload of exactly the limit', () {
      final bytes = encode(AdbMessage(AdbCommand.write, 1, 2, [1, 2, 3, 4]));
      expect((AdbMessageReader(maxPayload: 4)..add(bytes)).next(), isNotNull);
    });

    test('decodes the recorded bytes of every fixture, both directions, '
        'fed one byte at a time', () {
      for (final name in Fixture.all()) {
        final fixture = Fixture.load(name);
        for (final direction in FixtureDirection.values) {
          final expected = [
            for (final packet in fixture.packets)
              if (packet.direction == direction) packet.message,
          ];
          final reader = AdbMessageReader();
          final decoded = <AdbMessage>[];
          for (final byte in fixture.rawBytes(direction)) {
            reader.add([byte]);
            decoded.addAll(reader.drain());
          }
          expect(decoded, expected, reason: '$name $direction');
          expect(reader.bufferedLength, 0, reason: '$name $direction');
        }
      }
    });

    test('skips unknown and obsolete commands and reports them', () {
      final unknown = [0x12345678, AdbCommand.sync.value];
      final skipped = <(int, int)>[];
      final reader = AdbMessageReader(onUnknownCommand: (command, length) => skipped.add((command, length)));
      for (final value in unknown) {
        final bytes = Uint8List(27);
        ByteData.sublistView(bytes)
          ..setUint32(0, value, Endian.little)
          ..setUint32(12, 3, Endian.little)
          ..setUint32(20, value ^ 0xffffffff, Endian.little);
        reader.add(bytes);
      }
      reader.add(encode(AdbMessage.okay(localId: 1, remoteId: 2)));
      expect(reader.drain().single.command, AdbCommand.okay);
      expect(skipped, [(0x12345678, 3), (AdbCommand.sync.value, 3)]);
    });

    test('our encoder reproduces the recorded bytes after the handshake', () {
      // Online fixtures were recorded at protocol version 0x01000001, where
      // the checksum is 0 for messages from the device.
      for (final name in Fixture.all()) {
        final fixture = Fixture.load(name);
        if (!fixture.startsOnline) continue;
        for (final packet in fixture.packets) {
          if (packet.direction != FixtureDirection.fromDevice) continue;
          expect(encode(packet.message), packet.raw, reason: name);
        }
      }
    });
  });
}
