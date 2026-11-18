// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// The key the examples share: adbkey.pem in the working directory, made on first use. A device that once allowed it
// (or paired with it) lets every example in without asking again.

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

/// Loads `adbkey.pem`, or makes it.
Future<AdbKeyPair> loadKey() async {
  final file = File('adbkey.pem');
  if (file.existsSync()) return AdbKeyPair.fromPem(file.readAsStringSync(), comment: 'adb_direct@example');
  final key = await AdbKeyPair.generate(comment: 'adb_direct@example');
  file.writeAsStringSync(key.toPem());
  return key;
}

/// Connects to [host]:[port], saying what to do when the device asks its user.
Future<AdbConnection> connect(String host, String port) async {
  final key = await loadKey();
  return AdbConnection.connect(
    host,
    int.parse(port),
    key: key,
    onWaitingForApproval: () => print('Allow debugging on the device (key ${key.publicKey.md5Fingerprint})'),
  );
}
