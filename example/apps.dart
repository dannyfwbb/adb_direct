// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Installs, lists and removes apps, like `adb install` and `adb shell pm`:
//
//   dart run example/apps.dart 192.168.0.20 5555 install app.apk [split.apk…]
//   dart run example/apps.dart 192.168.0.20 5555 install-incremental app.apk   # app.apk.idsig next to it
//   dart run example/apps.dart 192.168.0.20 5555 list
//   dart run example/apps.dart 192.168.0.20 5555 uninstall com.example.app

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: apps <host> <port> install <apk>… | install-incremental <apk>… | list | uninstall <package>',
    );
    exitCode = 64;
    return;
  }
  final adb = await connect(args[0], args[1]);
  final files = args.skip(3).toList();
  try {
    switch (args[2]) {
      case 'install':
        final apks = [for (final path in files) AdbApk.file(File(path))];
        void progress(int done, int? total) => stdout.write('\r${100 * done ~/ (total ?? done).clamp(1, 1 << 62)}%');
        if (apks.length == 1) {
          await adb.packages.install(apks.single, onProgress: progress);
        } else {
          // A base APK and its splits, in one session.
          await adb.packages.installMultiple(apks, onProgress: progress);
        }
        print('\ninstalled');
      case 'install-incremental':
        final install = await adb.packages.installIncremental([
          for (final path in files) AdbIncrementalApk.file(File(path)),
        ]);
        print('installed; ${install.blocksSent} of ${install.totalBlocks} blocks sent so far');
        // The app can start now; the rest of its blocks follow. Keep the connection until they are all there.
        await install.done;
        print('all blocks sent');
      case 'list':
        for (final app in await adb.packages.list(system: false)) {
          print('${app.name}  ${app.versionCode ?? ''}  ${app.installer ?? ''}');
        }
      case 'uninstall':
        await adb.packages.uninstall(files.single);
        print('removed');
      default:
        stderr.writeln('unknown command ${args[2]}');
        exitCode = 64;
    }
  } on AdbInstallException catch (e) {
    // The package manager's code, such as INSTALL_FAILED_VERSION_DOWNGRADE, and its exact answer.
    stderr.writeln('\nfailed: ${e.failureCode ?? e.output.trim()}');
    exitCode = 1;
  } finally {
    await adb.close();
  }
}
