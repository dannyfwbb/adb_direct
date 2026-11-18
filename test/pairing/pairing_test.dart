// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/pairing/pairing_protocol.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_pairing_server.dart';

void main() {
  group('against the fake pairing server (both roles from one codebase)', () {
    test('the right code: the device GUID back, our key over there', () async {
      final device = await FakePairingServer.start(code: '482913', serverKey: otherKey);
      final paired = await AdbPairing.pair(
        '127.0.0.1',
        device.port,
        code: '482913',
        key: testKey,
        keyLog: device.keyLog.add,
      );
      expect(paired.guid, 'adb-FAKE0001-AbCdEf');
      expect(paired.certificate, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(device.pairedKeys, [testKey.publicKey.encode()]);
      await device.close();
    });

    test("a wrong code: the device's answer does not decrypt", () async {
      final device = await FakePairingServer.start(code: '482913', serverKey: otherKey);
      await expectLater(
        AdbPairing.pair('127.0.0.1', device.port, code: '482914', key: testKey, keyLog: device.keyLog.add),
        throwsA(isA<AdbPairingException>().having((e) => e.reason, 'reason', AdbPairingFailure.wrongCode)),
      );
      expect(device.pairedKeys, isEmpty);
      await device.close();
    });

    test('a wrong code: the device closes without answering', () async {
      final device = await FakePairingServer.start(
        code: '482913',
        serverKey: otherKey,
        mode: PairingServerMode.closeOnWrongCode,
      );
      await expectLater(
        AdbPairing.pair('127.0.0.1', device.port, code: '000000', key: testKey, keyLog: device.keyLog.add),
        throwsA(isA<AdbPairingException>().having((e) => e.reason, 'reason', AdbPairingFailure.wrongCode)),
      );
      await device.close();
    });

    test('a SPAKE2 message that is no point is a protocol failure', () async {
      final device = await FakePairingServer.start(code: '1', serverKey: otherKey, mode: PairingServerMode.badPoint);
      await expectLater(
        AdbPairing.pair('127.0.0.1', device.port, code: '1', key: testKey, keyLog: device.keyLog.add),
        throwsA(isA<AdbPairingException>().having((e) => e.reason, 'reason', AdbPairingFailure.protocol)),
      );
      await device.close();
    });

    test('a silent device: timeout; a cancel: cancelled', () async {
      final device = await FakePairingServer.start(code: '1', serverKey: otherKey, mode: PairingServerMode.silent);
      await expectLater(
        AdbPairing.pair('127.0.0.1', device.port, code: '1', key: testKey, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<AdbTimeoutException>()),
      );
      final cancel = Completer<void>();
      Timer(const Duration(milliseconds: 200), cancel.complete);
      await expectLater(
        AdbPairing.pair('127.0.0.1', device.port, code: '1', key: testKey, cancelOn: cancel.future),
        throwsA(isA<AdbCancelledException>()),
      );
      await device.close();
    });
  });

  test('no pairing server (the dialog was closed): refused', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    await expectLater(AdbPairing.pair('127.0.0.1', port, code: '1', key: testKey), throwsA(isA<AdbRefusedException>()));
  });

  group('wire format', () {
    test('packets: version 1, type, big-endian size', () {
      final packet = pairingPacket(PairingPacket.peerInfo, [1, 2, 3]);
      expect(packet, [1, 1, 0, 0, 0, 3, 1, 2, 3]);
    });

    test('a packet of 0 or more than 16384 bytes is refused', () async {
      for (final size in [0, 16385]) {
        final header = Uint8List(6)..[0] = 1;
        ByteData.sublistView(header).setUint32(2, size);
        final reader = PairingReader(Stream.value(header));
        await expectLater(reader.next(), throwsA(isA<AdbPairingException>()));
      }
    });

    test('PeerInfo is 8192 bytes, type first, zero padded', () {
      final info = PeerInfo.build(PeerInfo.rsaPublicKey, [65, 66]);
      expect(info, hasLength(8192));
      expect(info.sublist(0, 4), [0, 65, 66, 0]);
      expect(PeerInfo.parse(info), (0, 'AB'));
      expect(() => PeerInfo.build(0, List.filled(8191, 65)), throwsArgumentError);
    });

    test('GCM nonces count per direction; a wrong key does not decrypt', () {
      final key = List.filled(64, 7);
      final a = PairingCipher(key);
      final b = PairingCipher(key);
      final first = a.encrypt([1, 2, 3]);
      final second = a.encrypt([1, 2, 3]);
      expect(first, isNot(second), reason: 'counter 0, then 1');
      expect(first, hasLength(3 + 16));
      expect(b.decrypt(first), [1, 2, 3]);
      expect(b.decrypt(second), [1, 2, 3]);
      expect(PairingCipher(List.filled(64, 8)).decrypt(first), isNull);
      // Out of order: counter mismatch.
      expect(PairingCipher(key).decrypt(second), isNull);
    });
  });

  group('QR', () {
    test('the text and its parts', () {
      final qr = AdbPairingQr(serviceName: 'studio-abc', password: 'Pw123');
      expect(qr.text, 'WIFI:T:ADB;S:studio-abc;P:Pw123;;');
      final random = AdbPairingQr.random();
      expect(random.serviceName, matches(RegExp(r'^studio-[A-Za-z0-9]{10}$')));
      expect(random.password, hasLength(12));
      expect(AdbPairingQr.random().password, isNot(random.password));
      expect(() => AdbPairingQr(serviceName: 'studio;x', password: 'p'), throwsArgumentError);
    });

    test('waits for its own service, then pairs with the password', () async {
      final qr = AdbPairingQr.random();
      final device = await FakePairingServer.start(code: qr.password, serverKey: otherKey, guid: 'adb-QR-1');
      final services = StreamController<AdbPairingService>();
      final pairing = qr.pair(services: services.stream, key: testKey, keyLog: device.keyLog.add);
      // Another client's code first: ignored.
      services
        ..add(const AdbPairingService(name: 'studio-other', host: '127.0.0.1', port: 1))
        ..add(AdbPairingService(name: qr.serviceName, host: '127.0.0.1', port: device.port));
      expect((await pairing).guid, 'adb-QR-1');
      expect(device.pairedKeys, [testKey.publicKey.encode()]);
      await services.close();
      await device.close();
    });

    test('a code nobody scans times out', () async {
      final qr = AdbPairingQr.random();
      await expectLater(
        qr.pair(services: const Stream.empty(), key: testKey, waitTimeout: const Duration(milliseconds: 100)),
        throwsA(isA<AdbTimeoutException>()),
      );
    });
  });
}
