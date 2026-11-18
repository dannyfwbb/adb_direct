// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Wireless debugging (Android 11+): pairs this key with the code from "Pair device with pairing code", then connects
// over TLS, like `adb pair` and `adb connect`. Without a connection port, it is found on the network:
//
//   dart run example/pair.dart 192.168.0.20 37099 482913 [41235]
//
// 37099 is the pairing port shown with the code, 41235 the port under "IP address & Port".

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: pair <host> <pairing port> <code> [connection port]');
    exitCode = 64;
    return;
  }
  final host = args[0];
  final key = await loadKey();
  try {
    final paired = await AdbPairing.pair(host, int.parse(args[1]), code: args[2], key: key);
    print('paired with ${paired.guid}');
  } on AdbPairingException catch (e) {
    stderr.writeln(e.reason == AdbPairingFailure.wrongCode ? 'wrong code' : 'pairing failed: ${e.message}');
    exitCode = 1;
    return;
  } on AdbException catch (e) {
    // Refused: the pairing dialog was closed or the port is wrong; unreachable, timeout, …
    stderr.writeln('pairing failed (${e.code.name}): ${e.message}');
    exitCode = 1;
    return;
  }

  var port = args.length > 3 ? int.parse(args[3]) : null;
  if (port == null) {
    print('looking for the connection port…');
    final found = await AdbMdnsBrowser()
        .browse(const [AdbServiceType.tlsConnect])
        .where((e) => e is AdbServiceFound && e.service.addresses.any((a) => a.address == host))
        .first
        .timeout(const Duration(seconds: 15));
    port = found.service.port;
  }

  final adb = await AdbConnection.connect(host, port, key: key);
  print('connected over TLS to ${adb.device.model} (port $port)');
  await adb.close();
}
