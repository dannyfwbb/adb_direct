// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

/// Through a running adb server (port 5037) to the device it knows as
/// ADB_DIRECT_TEST_SERVER_SERIAL.
final String? serial = Platform.environment['ADB_DIRECT_TEST_SERVER_SERIAL'];
final String? skip = serial == null ? 'ADB_DIRECT_TEST_SERVER_SERIAL is not set (see test/device/README.md)' : null;

void main() {
  final server = AdbServer();

  test('version, devices, track-devices', () async {
    expect(await server.version(), greaterThanOrEqualTo(39));
    final devices = await server.devices();
    final device = devices.firstWhere((d) => d.serial == serial);
    expect(device.isOnline, isTrue);
    expect(device.model, isNotNull);
    final first = await server.trackDevices().first;
    expect(first.map((d) => d.serial), contains(serial));
  }, skip: skip);

  test('shell, files, an app and a forward through the server', () async {
    final adb = await server.device(serial!);
    addTearDown(adb.close);
    expect(adb.device.features, isNotEmpty);

    final r = await adb.shell.run('echo out; echo err >&2; exit 3');
    expect((r.stdoutText, r.exitCode), adb.shell.supportsShellProtocol ? ('out\n', 3) : (isA<String>(), 3));

    const path = '/data/local/tmp/adb_direct_server.bin';
    final data = Uint8List.fromList(List.generate(2 << 20, (i) => i * 7));
    final watch = Stopwatch()..start();
    await adb.sync.writeAll(path, data);
    final back = await adb.sync.readAll(path);
    print(
      'sync round trip of 2 MiB through the server: '
      '${watch.elapsedMilliseconds} ms',
    );
    expect(back, data);
    await adb.shell.run('rm -f $path');

    await adb.packages.install(AdbApk.file(File('test/fixtures/apks/app-v1.apk')));
    await adb.packages.uninstall('app.adbdirect.testapp');

    final logs = await adb.debug.logcat(arguments: ['-d', '-t', '5']).toList();
    expect(logs, isNotEmpty);
  }, skip: skip);

  test('reverse to a local port through the server', () async {
    final adb = await server.device(serial!);
    addTearDown(adb.close);
    if ((await adb.shell.run('toybox nc --help')).exitCode != 0) {
      markTestSkipped('no toybox nc');
      return;
    }
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((s) => s.listen(s.add, onDone: () => s.close()));
    final forward = await adb.reverse.toLocalPort('tcp:0', echo.port);
    final result = await adb.shell.run('(echo via server; sleep 2) | toybox nc 127.0.0.1 ${forward.devicePort}');
    expect(result.stdoutText, 'via server\n');
    await forward.remove();
    await expectLater(adb.reverse.add('tcp:0', (_) {}), throwsA(isA<AdbNotSupportedException>()));
    await echo.close();
  }, skip: skip);

  test('an unknown serial', () async {
    await expectLater(server.device('no-such-device'), throwsA(isA<AdbException>()));
  }, skip: skip);
}
