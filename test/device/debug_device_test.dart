// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

/// JDWP needs a debuggable app running on the device; bug reports take
/// minutes and run only with ADB_DIRECT_TEST_BUGREPORT=1.
final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(
  Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555',
);
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final bool bugreport = Platform.environment['ADB_DIRECT_TEST_BUGREPORT'] == '1';
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set '
          '(see test/device/README.md)'
    : null;

void main() {
  late AdbConnection adb;
  setUp(() async {
    if (skip != null) return;
    final key = AdbKeyPair.fromPem(File(keyPath!).readAsStringSync());
    adb = await AdbConnection.connect(host!, port, key: key);
  });
  tearDown(() async {
    if (skip == null) await adb.close();
  });

  test('track-jdwp, track-app and a JDWP handshake', () async {
    // Right after adbd restarted the first lists can be empty: the next
    // frames fill them.
    final pids = await adb.debug
        .trackJdwp()
        .firstWhere((p) => p.isNotEmpty)
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    print('debuggable pids: $pids');
    if (adb.supports(AdbFeature.trackApp)) {
      final apps = await adb.debug
          .trackApps()
          .firstWhere((a) => a.isNotEmpty)
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
      print('app processes: ${apps.length}');
      expect(apps, isNotEmpty);
      for (final pid in pids) {
        expect(apps.where((a) => a.pid == pid && a.debuggable), hasLength(1));
      }
    }
    if (pids.isEmpty) {
      markTestSkipped('no debuggable app runs: JDWP not tried');
      return;
    }
    final jdwp = await adb.debug.jdwp(pids.first);
    const handshake = 'JDWP-Handshake';
    await jdwp.write(ascii.encode(handshake));
    final reply = await jdwp.input.expand((b) => b).take(14).toList();
    expect(ascii.decode(reply), handshake);
    await jdwp.close();
  }, skip: skip);

  test('logcat and a screenshot', () async {
    final lines = await adb.debug
        .logcat(arguments: ['-d', '-t', '20'])
        .toList();
    expect(lines, isNotEmpty);
    final watch = Stopwatch()..start();
    final png = await adb.debug.screencap();
    print('screenshot ${png.length} B in ${watch.elapsedMilliseconds} ms');
    expect(png.sublist(1, 4), ascii.encode('PNG'));
  }, skip: skip);

  test(
    'a bug report',
    () async {
      final dir = Directory.systemTemp.createTempSync('bugreport');
      final file = File('${dir.path}/report.zip');
      var last = 0;
      final watch = Stopwatch()..start();
      await adb.debug.bugreport(
        file,
        onProgress: (done, total) {
          if (done * 10 ~/ total > last) {
            last = done * 10 ~/ total;
            print('bugreport ${last * 10}%');
          }
        },
      );
      print('bugreport ${file.lengthSync()} B in ${watch.elapsed.inSeconds} s');
      expect(file.readAsBytesSync().sublist(0, 2), ascii.encode('PK'));
      dir.deleteSync(recursive: true);
    },
    skip: skip ?? (bugreport ? null : 'set ADB_DIRECT_TEST_BUGREPORT=1'),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
