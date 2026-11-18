// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Pairs a key with a device and then connects over TLS with it:
///
/// ```
/// dart run tool/pair.dart <host> <pairing port> <code> <key file> [<connect port>]
/// ```
///
/// The key file is created (adb's PKCS#8 PEM) when missing.
library;

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: dart run tool/pair.dart <host> <pairing port> <code> <key file> [<connect port>]');
    exitCode = 64;
    return;
  }
  final [host, pairingPort, code, keyPath, ...rest] = args;
  final file = File(keyPath);
  final AdbKeyPair key;
  if (file.existsSync()) {
    key = AdbKeyPair.fromPem(file.readAsStringSync(), comment: 'adb_direct@pair');
  } else {
    key = await AdbKeyPair.generate(comment: 'adb_direct@pair');
    file.writeAsStringSync(key.toPem());
  }
  print('key ${key.publicKey.md5Fingerprint}');
  final watch = Stopwatch()..start();
  final paired = await AdbPairing.pair(host, int.parse(pairingPort), code: code, key: key);
  print('paired in ${watch.elapsedMilliseconds} ms: guid ${paired.guid}');
  if (rest.isEmpty) return;
  final adb = await AdbConnection.connect(host, int.parse(rest.first), key: key);
  final result = await adb.shell.run('getprop ro.product.model');
  print('TLS ${adb.isTls}: ${result.stdoutText.trim()}');
  await adb.close();
}
