// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Copies files and folders, like `adb push` and `adb pull`:
//
//   dart run example/files.dart 192.168.0.20 5555 push local.txt /sdcard/Download/local.txt
//   dart run example/files.dart 192.168.0.20 5555 pull /sdcard/Download ./download
//
// Folders are copied recursively; LZ4 compression is used where the device supports it.

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  if (args.length != 5 || !const ['push', 'pull'].contains(args[2])) {
    stderr.writeln('usage: files <host> <port> push <local> <remote> | pull <remote> <local>');
    exitCode = 64;
    return;
  }
  final adb = await connect(args[0], args[1]);
  void progress(int done, int? total) => stdout.write('\r$done${total == null ? '' : ' / $total'} bytes'.padRight(40));
  const compression = AdbCompression.lz4;

  try {
    if (args[2] == 'push') {
      final local = args[3];
      if (FileSystemEntity.isDirectorySync(local)) {
        final count = await adb.sync.pushDirectory(Directory(local), args[4], compression: compression);
        print('$count files pushed');
      } else {
        await adb.sync.pushFile(File(local), args[4], onProgress: progress, compression: compression);
        print('\npushed');
      }
    } else {
      final info = await adb.sync.stat(args[3], followLinks: adb.sync.canFollowLinks);
      if (info == null) {
        stderr.writeln('${args[3]}: no such file on the device');
        exitCode = 1;
      } else if (info.isDirectory) {
        final count = await adb.sync.pullDirectory(args[3], Directory(args[4]), compression: compression);
        print('$count files pulled');
      } else {
        await adb.sync.pullFile(args[3], File(args[4]), onProgress: progress, compression: compression);
        print('\npulled');
      }
    }
  } on AdbSyncException catch (e) {
    // The device refused: permission denied, read-only file system, no space…
    stderr.writeln('\n${e.path}: ${e.message}');
    exitCode = 1;
  } finally {
    await adb.close();
  }
}
