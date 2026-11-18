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
final String? globalSkip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set (see test/device/README.md)'
    : null;

/// When set, the same work also runs through the local adb server, to this device.
final String? serverSerial = Platform.environment['ADB_DIRECT_TEST_SERVER_SERIAL'];

const String scratch = '/data/local/tmp/adb_direct_stress';

/// Many kinds of work at once on one connection: every result must still be exact.
void main() {
  stress(
    'directly',
    () => AdbConnection.connect(host!, port, key: AdbKeyPair.fromPem(File(keyPath!).readAsStringSync())),
  );
  stress('through the adb server', () => AdbServer().device(serverSerial!), skip: serverSerial?.isNotEmpty != true);
}

void stress(String how, Future<AdbConnection> Function() connect, {bool skip = false}) {
  test(
    'shells, transfers (plain and LZ4), logcat, a forward and an install at the same time, $how',
    () async {
      final adb = await connect();
      addTearDown(() async {
        await adb.shell.run('rm -rf $scratch');
        await adb.close();
      });
      if ((await adb.properties.sdkLevel() ?? 0) < 24) {
        markTestSkipped('needs toybox (seq, sha256sum, nc): Android 7 and later');
        return;
      }
      await adb.shell.run('rm -rf $scratch; mkdir -p $scratch');
      // Android 7 has no sha256sum: there the pull-back check stands alone.
      final deviceHashes = (await adb.shell.run('command -v sha256sum')).stdoutText.trim().isNotEmpty;
      final random = Random(1);

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
        if (deviceHashes) {
          final remote = (await adb.shell.run('sha256sum $path')).stdoutText.split(' ').first;
          expect(remote, sha256.convert(data).toString(), reason: '$path on the device');
        }
      }

      /// A reverse from the device's tcp:18765 to an echo here: a handler, or through an adb server (where the device's
      /// connections reach local ports only) an echo server and toLocalPort. Null where the device refuses reverse.
      Future<AdbReverseForward?> echoBack() async {
        try {
          try {
            return await adb.reverse.add('tcp:18765', (stream) {
              stream.input.listen((data) => stream.write(data).ignore(), onDone: stream.close);
            });
          } on AdbNotSupportedException {
            final echo = await ServerSocket.bind('127.0.0.1', 0);
            addTearDown(echo.close);
            echo.listen((client) => client.listen(client.add, onDone: client.close));
            return await adb.reverse.toLocalPort('tcp:18765', echo.port);
          }
        } on AdbServiceUnavailableException catch (e) {
          // Emulators of Android 5 to 7 refuse reverse ("more than one device/emulator").
          printOnFailure('no reverse here: ${e.message}');
          return null;
        }
      }

      // Forward and reverse at once, with no tool on the device: a local socket goes to the device's tcp:18765 through
      // a forward, the device sends that connection back here through a reverse, and an echo answers.
      Future<void> forwarded() async {
        final reverse = await echoBack();
        if (reverse == null) return;
        final forward = await adb.forward('tcp:18765');
        addTearDown(() async {
          await forward.close();
          await reverse.remove();
        });
        final socket = await Socket.connect('127.0.0.1', forward.port);
        final payload = Uint8List.fromList(List.generate(300000, (i) => i * 13 & 0xff));
        final echoed = BytesBuilder();
        final received = Completer<void>();
        socket.listen((data) {
          echoed.add(data);
          if (echoed.length >= payload.length && !received.isCompleted) received.complete();
        });
        socket.add(payload);
        await received.future.timeout(const Duration(seconds: 60));
        socket.destroy();
        expect(echoed.takeBytes(), payload);
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
    skip: skip ? 'ADB_DIRECT_TEST_SERVER_SERIAL is not set' : globalSkip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
