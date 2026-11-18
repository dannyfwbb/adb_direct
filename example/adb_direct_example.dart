// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Connects to a device, tells what it is, runs a command and lists a directory:
//
//   dart run example/adb_direct_example.dart 192.168.0.20 5555
//
// The first time, the device asks "Allow debugging?" for this key, which is kept in adbkey.pem in the working
// directory. More examples: example/README.md.

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: adb_direct_example <host> <port>');
    exitCode = 64;
    return;
  }
  final AdbConnection adb;
  try {
    adb = await connect(args[0], args[1]);
  } on AdbException catch (e) {
    // Every failure is an AdbException with a stable code: unreachable, unauthorized, timeout, …
    stderr.writeln('Could not connect (${e.code.name}): ${e.message}');
    exitCode = 1;
    return;
  }

  print('Connected to ${adb.device.model}, Android API ${await adb.properties.sdkLevel()}');
  print('Serial number: ${await adb.properties.serialNumber() ?? 'none'}');

  final result = await adb.shell.run('uptime');
  print('uptime: ${result.stdoutText.trim()} (exit ${result.exitCode})');

  for (final entry in await adb.sync.list('/sdcard')) {
    print('${entry.stat.isDirectory ? 'd' : '-'} ${entry.stat.size.toString().padLeft(10)} ${entry.name}');
  }
  await adb.close();
}
