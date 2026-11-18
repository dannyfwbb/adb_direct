// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart' show otherKey;

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set '
          '(see test/device/README.md)'
    : null;

void main() {
  late AdbKeyPair key;
  // What the device offers: old ones have no authentication, no shell
  // protocol v2 and no stat v2; the tests check what each should do.
  late bool authenticates;
  late bool shellV2;
  setUpAll(() async {
    if (skip == null) {
      key = AdbKeyPair.fromPem(File(keyPath!).readAsStringSync());
      authenticates = (await AdbProbe.identify(host!, port)).kind == AdbEndpointKind.adbAuthentication;
      final adb = await AdbConnection.connect(host!, port, key: key);
      shellV2 = adb.shell.supportsShellProtocol;
      await adb.close();
    }
  });

  Future<AdbConnection> connect() => AdbConnection.connect(host!, port, key: key);

  test('connects and reads the banner', () async {
    final adb = await connect();
    addTearDown(adb.close);
    printOnFailure('${adb.device}');
    expect(adb.device.state, AdbDeviceState.device);
    expect(adb.device.model, isNotEmpty);
    expect(adb.acceptedKey, authenticates ? key : isNull);
  }, skip: skip);

  test('runs commands with separate output and the exit status', () async {
    final adb = await connect();
    addTearDown(adb.close);
    final result = await adb.shell.run('echo hi; echo err >&2; exit 3');
    if (shellV2) {
      expect(result.stdoutText, 'hi\n');
      expect(result.stderrText, 'err\n');
    } else {
      // One stream for both, no CR from a PTY.
      expect(result.separateStreams, isFalse);
      expect(result.stdoutText, 'hi\nerr\n');
    }
    expect(result.exitCode, 3);
    final sdk = await adb.shell.run('getprop ro.build.version.sdk');
    expect(int.parse(sdk.stdoutText.trim()), greaterThanOrEqualTo(19));
  }, skip: skip);

  test('reads stdin until EOF (closed stdin)', () async {
    final adb = await connect();
    addTearDown(adb.close);
    final result = await adb.shell.run('cat; echo done');
    expect(result.stdoutText, 'done\n');
  }, skip: skip);

  test('many commands in parallel over one connection', () async {
    final adb = await connect();
    addTearDown(adb.close);
    final results = await Future.wait([for (var i = 0; i < 20; i++) adb.shell.run('echo $i')]);
    expect(results.map((r) => r.stdoutText.trim()), [for (var i = 0; i < 20; i++) '$i']);
  }, skip: skip);

  test('an unknown service is refused and the connection lives on', () async {
    final adb = await connect();
    addTearDown(adb.close);
    await expectLater(adb.open('adb_direct-no-such-service:'), throwsA(isA<AdbServiceUnavailableException>()));
    expect((await adb.shell.run('echo ok')).stdoutText, 'ok\n');
  }, skip: skip);

  test(
    'downloads 64 MiB through exec with flow control',
    () async {
      final adb = await connect();
      addTearDown(adb.close);
      const size = 64 * 1024 * 1024;
      final stopwatch = Stopwatch()..start();
      // dd: old devices have no head.
      final AdbStream stream;
      try {
        stream = await adb.shell.exec('dd if=/dev/zero bs=1048576 count=64 2>/dev/null');
      } on AdbServiceUnavailableException {
        markTestSkipped('no exec: before Android 5');
        return;
      }
      var total = 0;
      await for (final chunk in stream.input) {
        total += chunk.length;
      }
      final seconds = stopwatch.elapsedMilliseconds / 1000;
      printOnFailure('64 MiB in $seconds s, delayed ACK ${adb.delayedAck}');
      print(
        'download: ${(size / 1024 / 1024 / seconds).toStringAsFixed(1)} '
        'MiB/s, delayed ACK ${adb.delayedAck}',
      );
      expect(total, size);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'uploads 16 MiB through stdin',
    () async {
      if (!shellV2) {
        markTestSkipped('needs shell protocol v2 to close stdin');
        return;
      }
      final adb = await connect();
      addTearDown(adb.close);
      const size = 16 * 1024 * 1024;
      final shell = await adb.shell.start(command: 'wc -c', pty: false);
      final output = shell.stdout.toList();
      final chunk = List<int>.filled(1024 * 1024, 0x61);
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < size ~/ chunk.length; i++) {
        await shell.write(chunk);
      }
      await shell.closeStdin();
      final counted = String.fromCharCodes((await output).expand((b) => b));
      final seconds = stopwatch.elapsedMilliseconds / 1000;
      print('upload: ${(size / 1024 / 1024 / seconds).toStringAsFixed(1)} MiB/s');
      expect(int.parse(counted.trim()), size);
      expect(await shell.exitCode, 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('probes: identify and knowsKey never prompt', () async {
    final endpoint = await AdbProbe.identify(host!, port);
    expect(endpoint.isAdb, isTrue);
    expect(await AdbProbe.knowsKey(host!, port, key), isTrue);
    // A device without authentication trusts every key.
    expect(await AdbProbe.knowsKey(host!, port, otherKey), !authenticates);
  }, skip: skip);

  test('an interactive shell with a PTY', () async {
    final adb = await connect();
    addTearDown(adb.close);
    final shell = await adb.shell.start(command: 'sh');
    final output = StringBuffer();
    final seen = shell.stdout.listen((data) => output.write(String.fromCharCodes(data)));
    if (shellV2) {
      await shell.resize(rows: 40, columns: 100);
      // Android 7 has no stty; mksh keeps LINES and COLUMNS up to date.
      await shell.write('stty size 2>/dev/null || echo "\$LINES \$COLUMNS"; exit 5\n'.codeUnits);
      expect(await shell.exitCode, 5);
      await seen.cancel();
      expect(output.toString(), contains('40 100'));
    } else {
      // No window size and no exit status without the protocol.
      await shell.write('echo pty-ok; exit 5\n'.codeUnits);
      expect(await shell.exitCode, isNull);
      await seen.cancel();
      expect(output.toString(), contains('pty-ok'));
    }
  }, skip: skip);
}
