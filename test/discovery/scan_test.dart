// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';

/// A browser that replays [events].
final class ListBrowser implements AdbServiceBrowser {
  ListBrowser(this.events);
  final List<AdbServiceEvent> events;
  List<String>? asked;

  @override
  Stream<AdbServiceEvent> browse(List<String> types) {
    asked = types;
    return Stream.fromIterable(events);
  }
}

void main() {
  test('scan: only what speaks ADB, never a key offered', () async {
    // adbd asking for authentication; it must see no AUTH from us.
    final adbd = await FakeAdbd.start((session) async {
      final cnxn = await session.receive();
      expect(cnxn.command, AdbCommand.connect);
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.expectClientClose();
    });
    // Something else: talks HTTP.
    final web = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    web.listen((s) {
      s.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      unawaited(s.close());
    });
    // Nothing listens.
    final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = gone.port;
    await gone.close();

    final results = await AdbProbe.scan([
      ('127.0.0.1', web.port),
      ('127.0.0.1', adbd.port),
      ('127.0.0.1', closedPort),
    ]).toList();
    expect(results.map((r) => (r.port, r.endpoint.kind)), [
      (adbd.port, AdbEndpointKind.adbAuthentication),
    ]);
    await adbd.done();
    await web.close();
  });

  test('scan: at most `concurrency` probes at a time', () async {
    // A server that accepts and says nothing: each probe waits for its
    // timeout. 12 targets, 3 at a time, 150 ms each: at least 4 rounds.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    silent.listen(sockets.add);
    final watch = Stopwatch()..start();
    final results = await AdbProbe.scan(
      List.filled(12, ('127.0.0.1', silent.port)),
      concurrency: 3,
      timeout: const Duration(milliseconds: 150),
    ).toList();
    expect(results, isEmpty);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(4 * 150 - 20));
    expect(watch.elapsedMilliseconds, lessThan(12 * 150));
    for (final s in sockets) {
      s.destroy();
    }
    await silent.close();
  });

  test('pairing services from any browser, for QR pairing', () async {
    final service = AdbService(
      type: AdbServiceType.tlsPairing,
      instance: 'studio-AbCdEf1234',
      port: 37099,
      addresses: [InternetAddress('192.168.0.20')],
    );
    final browser = ListBrowser([
      AdbServiceFound(service),
      AdbServiceLost(service),
    ]);
    final found = await browser.pairingServices().toList();
    expect(browser.asked, [AdbServiceType.tlsPairing]);
    expect(found.map((s) => (s.name, s.port)), [('studio-AbCdEf1234', 37099)]);
  });

  test('scan: an empty list ends at once; a failing list reports it', () async {
    expect(await AdbProbe.scan(const []).toList(), isEmpty);
    Iterable<(Object, int)> failing() sync* {
      throw StateError('no targets');
    }

    await expectLater(AdbProbe.scan(failing()).toList(), throwsStateError);
  });
}
