// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

/// A wireless debugging (TLS) port: ADB_DIRECT_TEST_TLS_PORT on
/// ADB_DIRECT_TEST_HOST (see test/device/README.md, "TLS").
final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int? port = int.tryParse(Platform.environment['ADB_DIRECT_TEST_TLS_PORT'] ?? '');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];

/// Where to save the device's certificate (DER), when set.
final String? certificateOut = Platform.environment['ADB_DIRECT_TEST_TLS_CERT_OUT'];

final String? skip = host == null || port == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST, ADB_DIRECT_TEST_TLS_PORT and '
          'ADB_DIRECT_TEST_KEY are not set (see test/device/README.md)'
    : null;

void main() {
  late AdbKeyPair key;
  setUpAll(() {
    if (skip == null) {
      key = AdbKeyPair.fromPem(File(keyPath!).readAsStringSync());
    }
  });

  test('TLS: STLS, the handshake with our certificate, CNXN', () async {
    final watch = Stopwatch()..start();
    final adb = await AdbConnection.connect(host!, port!, key: key);
    final elapsed = watch.elapsedMilliseconds;
    expect(adb.isTls, isTrue);
    expect(adb.deviceCertificate, isNotNull);
    if (certificateOut case final out?) {
      File(out).writeAsBytesSync(adb.deviceCertificate!);
    }
    print(
      'TLS connect $elapsed ms; version 0x${adb.protocolVersion.toRadixString(16)}, '
      'maxdata ${adb.maxPayload}, delayed ACK ${adb.delayedAck}; '
      '${adb.device.model}',
    );
    await adb.close();
  }, skip: skip);

  test('TLS: shell, a big answer and files', () async {
    final adb = await AdbConnection.connect(host!, port!, key: key);
    final echo = await adb.shell.run('echo over tls; echo err >&2; exit 4');
    expect(echo.stdoutText, 'over tls\n');
    expect(echo.stderrText, 'err\n');
    expect(echo.exitCode, 4);

    final watch = Stopwatch()..start();
    final big = await adb.shell.run('head -c 20000000 /dev/zero', maxOutputBytes: 32 * 1024 * 1024);
    final ms = watch.elapsedMilliseconds;
    expect(big.stdout.length, 20000000);
    print(
      'TLS download 20 MB in $ms ms '
      '(${(20000000 / 1048576 / (ms / 1000)).toStringAsFixed(0)} MiB/s)',
    );

    const path = '/data/local/tmp/adb_direct_tls.bin';
    final data = Uint8List.fromList(List.generate(3000000, (i) => i * 7));
    final up = Stopwatch()..start();
    await adb.sync.write(path, Stream.value(data), size: data.length);
    final upMs = up.elapsedMilliseconds;
    final back = await adb.sync.read(path).expand((c) => c).toList();
    expect(back, data);
    print('TLS push 3 MB in $upMs ms');
    await adb.shell.run('rm -f $path');
    expect(utf8.decode((await adb.shell.run('echo ok')).stdout), 'ok\n');
    await adb.close();
  }, skip: skip);
}
