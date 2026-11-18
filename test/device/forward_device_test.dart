// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set '
          '(see test/device/README.md)'
    : null;

/// Sends [data] to [port] here and reads until the peer closes.
Future<List<int>> roundTrip(int port, List<int> data) async {
  final socket = await Socket.connect('127.0.0.1', port);
  socket.add(data);
  await socket.flush();
  final got = <int>[];
  final done = Completer<void>();
  socket.listen((d) {
    got.addAll(d);
    if (got.length >= data.length && !done.isCompleted) done.complete();
  }, onDone: () => done.isCompleted ? null : done.complete());
  await done.future.timeout(const Duration(seconds: 20));
  socket.destroy();
  return got;
}

void main() {
  late AdbConnection adb;
  setUp(() async {
    if (skip != null) return;
    final key = AdbKeyPair.fromPem(File(keyPath!).readAsStringSync());
    adb = await AdbConnection.connect(host!, port, key: key);
  });

  /// The device side of these tests needs toybox's nc (Android 6 and
  /// later); older devices have none.
  Future<bool> hasNc() async {
    final ok = (await adb.shell.run('toybox nc --help')).exitCode == 0;
    if (!ok) markTestSkipped('no toybox nc on this device');
    return ok;
  }

  /// Old adbd (Android 5 on the emulator) refuses reverse with "more than
  /// one device and emulator".
  Future<T?> reverse<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AdbServiceUnavailableException catch (e) {
      if (!e.message.contains('more than one device')) rethrow;
      markTestSkipped('this adbd cannot reverse: ${e.message}');
      return null;
    }
  }

  tearDown(() async {
    if (skip == null) await adb.close();
  });

  test('forward: a local port to an echo server on the device', () async {
    if (!await hasNc()) return;
    // An echo server on the device, alive while this stream is open.
    final server = await adb.open('exec:toybox nc -s 127.0.0.1 -p 18090 -L cat');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final forward = await adb.forward('tcp:18090');
    expect(forward.port, isPositive);
    expect(utf8.decode(await roundTrip(forward.port, utf8.encode('over adb\n'))), 'over adb\n');
    // Several at once, and a big one (flow control both ways).
    final big = Uint8List.fromList(List.generate(3 << 20, (i) => i * 31));
    final watch = Stopwatch()..start();
    final results = await Future.wait([roundTrip(forward.port, big), roundTrip(forward.port, utf8.encode('second\n'))]);
    expect(results[0], big);
    expect(utf8.decode(results[1]), 'second\n');
    print('forward echo of 3 MiB in ${watch.elapsedMilliseconds} ms');
    await forward.close();
    expect(forward.isClosed, isTrue);
    await server.close();
  }, skip: skip);

  test('forward: a service the device refuses closes the local peer', () async {
    final forward = await adb.forward('tcp:1');
    final socket = await Socket.connect('127.0.0.1', forward.port);
    await socket.drain<void>().timeout(const Duration(seconds: 10));
    socket.destroy();
    await forward.close();
  }, skip: skip);

  test('reverse: a device port to a local echo server', () async {
    if (!await hasNc()) return;
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((s) => s.listen(s.add, onDone: () => s.close()));
    final forward = await reverse(() => adb.reverse.toLocalPort('tcp:0', echo.port));
    if (forward == null) {
      await echo.close();
      return;
    }
    expect(forward.devicePort, isPositive);
    expect(await adb.reverse.list(), contains(AdbReverseEntry(forward.deviceSpec, 'tcp:${echo.port}')));
    final result = await adb.shell.run(
      // stdin stays open a moment: toybox nc drops the connection at once
      // on EOF, before sending.
      '(echo hello from the device; sleep 2) | toybox nc 127.0.0.1 '
      '${forward.devicePort}',
    );
    expect(result.stdoutText, 'hello from the device\n');
    await forward.remove();
    expect(await adb.reverse.list(), isEmpty);
    await echo.close();
  }, skip: skip);

  test('reverse: connections handled in code; refusals', () async {
    if (!await hasNc()) return;
    final forward = await reverse(
      () => adb.reverse.add('tcp:0', (stream) {
        // Reading must not cancel the input (`first` would): cancelling it
        // closes the stream.
        stream.input.listen((request) async {
          await stream.write(utf8.encode('got ${utf8.decode(request)}'));
          await stream.flush();
          await stream.close();
        });
      }),
    );
    if (forward == null) return;
    final result = await adb.shell.run('(echo ping; sleep 2) | toybox nc 127.0.0.1 ${forward.devicePort}');
    expect(result.stdoutText, 'got ping\n');
    await expectLater(
      adb.reverse.add(forward.deviceSpec, (_) {}, rebind: false),
      throwsA(isA<AdbServiceUnavailableException>()),
    );
    await expectLater(adb.reverse.remove('tcp:1'), throwsA(isA<AdbServiceUnavailableException>()));
    await adb.reverse.removeAll();
    expect(await adb.reverse.list(), isEmpty);
  }, skip: skip);
}
