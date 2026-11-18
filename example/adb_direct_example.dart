// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Connects to a device, runs a command, lists a directory and installs an APK:
//
//   dart run example/adb_direct_example.dart 192.168.0.20 5555 [app.apk]
//
// The first time, the device asks "Allow debugging?" for this key, which is kept in adbkey.pem next to the working
// directory.

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: adb_direct_example <host> <port> [app.apk]');
    exitCode = 64;
    return;
  }
  final keyFile = File('adbkey.pem');
  final key = keyFile.existsSync()
      ? AdbKeyPair.fromPem(keyFile.readAsStringSync())
      : await AdbKeyPair.generate(comment: 'adb_direct@example');
  if (!keyFile.existsSync()) keyFile.writeAsStringSync(key.toPem());

  final adb = await AdbConnection.connect(
    args[0],
    int.parse(args[1]),
    key: key,
    onWaitingForApproval: () => print('Allow debugging on the device (key ${key.publicKey.md5Fingerprint})'),
  );
  print('Connected to ${adb.device.model}');

  final result = await adb.shell.run('getprop ro.build.version.release');
  print('Android ${result.stdoutText.trim()}');

  for (final entry in await adb.sync.list('/sdcard')) {
    print('${entry.stat.isDirectory ? 'd' : '-'} ${entry.name}');
  }

  if (args.length > 2) {
    await adb.packages.install(
      AdbApk.file(File(args[2])),
      onProgress: (done, total) => stdout.write('\r$done / $total bytes'),
    );
    print('\nInstalled');
  }
  await adb.close();
}
