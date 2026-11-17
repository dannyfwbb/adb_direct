// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

/// adbd's own services. On ADB_DIRECT_TEST_HOST:ADB_DIRECT_TEST_PORT:
/// `tcpip` (on the same port) and `waitFor`, and `root` as the build
/// allows. Root, remount and unroot need a rootable device: set
/// ADB_DIRECT_TEST_ROOTABLE=1 (the phone emulator, never a real TV).
/// Reboot is not a test: see test/device/README.md.
final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(
  Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555',
);
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final bool rootable = Platform.environment['ADB_DIRECT_TEST_ROOTABLE'] == '1';
final String? devicePort = Platform.environment['ADB_DIRECT_TEST_DEVICE_PORT'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set '
          '(see test/device/README.md)'
    : null;

void main() {
  late AdbKeyPair key;
  setUpAll(() {
    if (skip == null) {
      key = AdbKeyPair.fromPem(File(keyPath!).readAsStringSync());
    }
  });

  Future<AdbConnection> back() async {
    final watch = Stopwatch()..start();
    final adb = await AdbConnection.waitFor(
      host!,
      port,
      key: key,
      timeout: const Duration(seconds: 60),
    );
    print('back after ${watch.elapsedMilliseconds} ms');
    return adb;
  }

  test('tcpip on the port in use: adbd restarts, waitFor reconnects', () async {
    final adb = await AdbConnection.connect(host!, port, key: key);
    final answer = await adb.daemon.tcpip(int.parse(devicePort ?? '5555'));
    expect(answer.outcome, AdbDaemonOutcome.restarting);
    expect(answer.output, contains('restarting in TCP mode port:'));
    expect(adb.isClosed, isTrue);
    final again = await back();
    expect((await again.shell.run('echo ok')).stdoutText, 'ok\n');
    await again.close();
  }, skip: skip);

  test('root as the build allows', () async {
    final adb = await AdbConnection.connect(host!, port, key: key);
    final answer = await adb.daemon.root();
    print('root: $answer');
    if (rootable) {
      expect(
        answer.outcome,
        anyOf(AdbDaemonOutcome.restarting, AdbDaemonOutcome.unchanged),
      );
      final root = answer.restarting ? await back() : adb;
      expect((await root.shell.run('id -u')).stdoutText.trim(), '0');
      final remount = await root.daemon.remount();
      print('remount: $remount');
      expect(remount.output, isNotEmpty);
      final unroot = await root.daemon.unroot();
      expect(unroot.outcome, AdbDaemonOutcome.restarting);
      final shell = await back();
      expect((await shell.shell.run('id -u')).stdoutText.trim(), isNot('0'));
      final again = await shell.daemon.unroot();
      expect(again.outcome, AdbDaemonOutcome.unchanged);
      await shell.close();
    } else {
      expect(answer.outcome, AdbDaemonOutcome.refused);
      expect(adb.isClosed, isFalse);
      final unroot = await adb.daemon.unroot();
      expect(unroot.outcome, AdbDaemonOutcome.unchanged);
      await adb.close();
    }
  }, skip: skip);
}
