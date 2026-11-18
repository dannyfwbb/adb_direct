// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set (see test/device/README.md)'
    : null;

const String scratch = '/data/local/tmp/adb_direct_stress';

/// Many kinds of work at once on one connection: every result must still be exact.
void main() {
  test(
    'shells, transfers (plain and LZ4), logcat, a forward and an install at the same time',
    () async {
      final adb = await AdbConnection.connect(host!, port, key: AdbKeyPair.fromPem(File(keyPath!).readAsStringSync()));
      addTearDown(() async {
        await adb.shell.run('rm -rf $scratch');
        await adb.close();
      });
      await adb.shell.run('rm -rf $scratch; mkdir -p $scratch');
      final random = Random(1);
      final hasExec = (await adb.properties.sdkLevel() ?? 0) >= 21;

      // Background: logcat following the log, consumed slowly.
      var logLines = 0;
      final logcat = adb.debug.logcat().listen((_) => logLines++);

      Future<void> shells() async {
        await Future.wait([
          for (var i = 0; i < 30; i++)
            adb.shell.run('echo $i; seq 1 ${200 * i} | tail -n 1').then((r) {
              final lines = LineSplitter.split(r.stdoutText).toList();
              expect(lines.first, '$i');
              if (i > 0) expect(lines.last, '${200 * i}');
            }),
        ]);
      }

      Future<void> transfer(int n, AdbCompression? compression) async {
        final size = 1 << (18 + n % 4);
        final data = Uint8List.fromList(
          List.generate(size, (i) => n.isEven ? random.nextInt(256) : (i ~/ 97 + n) & 0xff),
        );
        final path = '$scratch/f$n';
        await adb.sync.writeAll(path, data, compression: compression);
        final back = await adb.sync.readAll(path, compression: compression);
        expect(sha256.convert(back), sha256.convert(data), reason: path);
        final remote = (await adb.shell.run('sha256sum $path')).stdoutText.split(' ').first;
        expect(remote, sha256.convert(data).toString(), reason: '$path on the device');
      }

      Future<void> forwarded() async {
        if (!hasExec) return;
        // A device-side echo through `exec:cat` is not a TCP service; use a forward to an abstract socket served by
        // toybox nc where it exists, else skip.
        final nc = await adb.shell.run('command -v nc');
        if (nc.stdoutText.trim().isEmpty) return;
        // toybox nc quits as soon as its stdin ends, before reading the network: keep stdin open.
        final listener = adb.shell.run(
          'sleep 29.7 | nc -l -p 18765 -s 127.0.0.1 > $scratch/nc.out',
          timeout: const Duration(seconds: 60),
        );
        // Under load nc may take a while to listen; a forward to a closed port is refused by the device.
        for (var i = 0; i < 100; i++) {
          final listening = await adb.shell.run('cat /proc/net/tcp | grep -ci ":494D 00000000:0000 0A"');
          if (listening.stdoutText.trim() != '0') break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final forward = await adb.forward('tcp:18765');
        addTearDown(forward.close);
        final socket = await Socket.connect('127.0.0.1', forward.port);
        final payload = Uint8List.fromList(List.generate(300000, (i) => i * 13 & 0xff));
        socket.add(payload);
        await socket.flush();
        await socket.close();
        // Wait for nc to have written everything.
        for (var i = 0; i < 50; i++) {
          final size = (await adb.sync.stat('$scratch/nc.out'))?.size ?? 0;
          if (size >= payload.length) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(await adb.sync.readAll('$scratch/nc.out'), payload);
        await adb.shell.run('pkill -f "nc -l -p 18765"; pkill -f "sleep 29.7"');
        await listener;
      }

      Future<void> install() async {
        await adb.packages.install(AdbApk.file(File('test/fixtures/apks/app-v2.apk')));
        expect(await adb.packages.paths('app.adbdirect.testapp'), isNotEmpty);
        await adb.packages.uninstall('app.adbdirect.testapp');
      }

      await Future.wait([
        shells(),
        for (var n = 0; n < 8; n++) transfer(n, n % 3 == 0 ? null : AdbCompression.lz4),
        forwarded(),
        install(),
        shells(),
      ]);
      await logcat.cancel();
      expect(logLines, greaterThan(0));
      expect(adb.isClosed, isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
