// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

/// A fake that expects one CNXN and answers with [answer] (or nothing).
Future<FakeAdbd> answering(void Function(FakeAdbdSession session) answer) => FakeAdbd.start((session) async {
  final cnxn = await session.receive();
  expect(cnxn.command, AdbCommand.connect);
  answer(session);
  await session.expectClientClose();
});

void main() {
  group('identify', () {
    test('AUTH: classic network debugging', () async {
      final adbd = await answering((s) => s.send(AdbMessage.auth(AdbAuthType.token, randomToken())));
      final endpoint = await AdbProbe.identify(adbd.address, adbd.port);
      expect(endpoint.kind, AdbEndpointKind.adbAuthentication);
      expect(endpoint.isAdb, isTrue);
      await adbd.done();
    });

    test('CNXN: no authentication, with the banner', () async {
      final adbd = await answering((s) => s.send(AdbMessage(AdbCommand.connect, AdbProtocol.version, 4096, tvBanner)));
      final endpoint = await AdbProbe.identify(adbd.address, adbd.port);
      expect(endpoint.kind, AdbEndpointKind.adbOpen);
      expect(endpoint.banner!.model, 'AOSP TV on x86');
      await adbd.done();
    });

    test('STLS: a wireless debugging port', () async {
      final adbd = await answering((s) => s.send(AdbMessage.stls()));
      expect((await AdbProbe.identify(adbd.address, adbd.port)).kind, AdbEndpointKind.adbTls);
      await adbd.done();
    });

    test('something else (an HTTP server) is not adbd', () async {
      final adbd = await answering((s) => s.sendRaw('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits));
      expect((await AdbProbe.identify(adbd.address, adbd.port)).kind, AdbEndpointKind.notAdb);
      await adbd.done();
    });

    test('silence is not adbd', () async {
      final clock = FakeClock();
      final adbd = await answering((s) => clock.advance(const Duration(seconds: 4)));
      expect((await AdbProbe.identify(adbd.address, adbd.port, clock: clock)).kind, AdbEndpointKind.notAdb);
      await adbd.done();
    });

    test('a closed port is refused', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      await expectLater(AdbProbe.identify(InternetAddress.loopbackIPv4, port), throwsA(isA<AdbRefusedException>()));
    });
  });

  group('knowsKey', () {
    test('true when the device accepts the signature', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session);
        await session.expectClientClose();
      });
      expect(await AdbProbe.knowsKey(adbd.address, adbd.port, testKey), isTrue);
      await adbd.done();
    });

    test('false, without ever offering the key, when it does not', () async {
      final adbd = await FakeAdbd.start((session) async {
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        final signature = await session.receive();
        expect(signature.arg0, AdbAuthType.signature.value);
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        // The fake fails on any message here, the public key included.
        await session.expectClientClose();
      });
      expect(await AdbProbe.knowsKey(adbd.address, adbd.port, otherKey), isFalse);
      await adbd.done();
    });
  });
}
