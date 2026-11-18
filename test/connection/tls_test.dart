// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_tls_adbd.dart';

Future<String> echo(AdbConnection adb, String text) async {
  final stream = await adb.open('echo:$text');
  final bytes = await stream.input.expand((b) => b).toList();
  return utf8.decode(bytes);
}

void main() {
  test('a trusted key: STLS, TLS, CNXN inside; streams work', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [testKey], serverKey: otherKey);
    final adb = await AdbConnection.connect('127.0.0.1', adbd.port, key: testKey);
    expect(adb.isTls, isTrue);
    expect(adb.deviceCertificate, adbd.certificateDer);
    expect(adb.acceptedKey, testKey);
    expect(adb.device.properties['ro.product.model'], 'TLS TV');
    expect(await echo(adb, 'over tls'), 'over tls');
    expect(await echo(adb, 'again'), 'again');
    await adb.close();
    expect(adbd.connections, 1);
    await adbd.close();
  });

  test('a key the device does not trust: unauthorized, one try', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [otherKey], serverKey: otherKey);
    await expectLater(
      AdbConnection.connect('127.0.0.1', adbd.port, key: testKey),
      throwsA(isA<AdbUnauthorizedException>().having((e) => e.message, 'message', contains('pair it first'))),
    );
    expect(adbd.connections, 1);
    await adbd.close();
  });

  test('several keys: one TLS session each until one is trusted', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [otherKey], serverKey: testKey);
    final adb = await AdbConnection.connect('127.0.0.1', adbd.port, key: testKey, extraKeys: [otherKey]);
    expect(adb.acceptedKey, otherKey);
    expect(adbd.connections, 2);
    expect(await echo(adb, 'second key'), 'second key');
    await adb.close();
    await adbd.close();
  });

  test('a device that answers STLS but speaks no TLS', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [testKey], serverKey: otherKey, speakTls: false);
    await expectLater(AdbConnection.connect('127.0.0.1', adbd.port, key: testKey), throwsA(isA<AdbException>()));
    await adbd.close();
  });

  test('a TLS handshake that never finishes: timeout', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [testKey], serverKey: otherKey, hangAfterStls: true);
    final watch = Stopwatch()..start();
    await expectLater(
      AdbConnection.connect(
        '127.0.0.1',
        adbd.port,
        key: testKey,
        options: const AdbConnectOptions(handshakeTimeout: Duration(milliseconds: 400)),
      ),
      throwsA(isA<AdbTimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    await adbd.close();
  });

  test('a TLS handshake that never finishes: cancel', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [testKey], serverKey: otherKey, hangAfterStls: true);
    final cancel = Completer<void>();
    Timer(const Duration(milliseconds: 200), cancel.complete);
    final watch = Stopwatch()..start();
    await expectLater(
      AdbConnection.connect('127.0.0.1', adbd.port, key: testKey, cancelOn: cancel.future),
      throwsA(isA<AdbCancelledException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    await adbd.close();
  });

  test('an untrusted key: the close is kept as the cause', () async {
    final adbd = await FakeTlsAdbd.start(trusted: [otherKey], serverKey: otherKey);
    await expectLater(
      AdbConnection.connect('127.0.0.1', adbd.port, key: testKey),
      throwsA(isA<AdbUnauthorizedException>().having((e) => e.cause, 'cause', isA<AdbException>())),
    );
    await adbd.close();
  });

  test('a classic connection reports no TLS', () async {
    final adbd = await FakeAdbd.start((session) async {
      await acceptHandshake(session);
      await session.expectClientClose();
    });
    final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
    expect(adb.isTls, isFalse);
    expect(adb.deviceCertificate, isNull);
    await adb.close();
    await adbd.done();
  });
}
