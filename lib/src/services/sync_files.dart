// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/sync_protocol.dart';
import 'shell.dart';
import 'sync.dart';
import 'sync_compression.dart';

/// Local files and directories with [AdbSync], like `adb pull` and `adb push`.
extension AdbSyncFiles on AdbSync {
  /// Copies the device file [remote] to [local], replacing it.
  ///
  /// The local file gets the device file's modification time. A failed transfer leaves no partial file behind.
  /// [compression] as in [AdbSync.read].
  Future<void> pullFile(String remote, File local, {AdbProgress? onProgress, AdbCompression? compression}) async {
    final info = await _target(remote);
    final partial = File('${local.path}.${randomHex()}.part');
    final sink = partial.openWrite();
    try {
      await sink.addStream(
        read(remote, compression: compression, onProgress: (done, _) => onProgress?.call(done, info?.size)),
      );
      await sink.close();
      await partial.rename(local.path);
    } on Object {
      await sink.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    if (info != null) await local.setLastModified(info.modified);
  }

  /// Copies [local] to the device path [remote], keeping its modification time and owner permission bits. On Android 7
  /// to 9 the parent directory must exist ([pushDirectory] makes the tree). [compression] as in [AdbSync.write].
  Future<void> pushFile(File local, String remote, {AdbProgress? onProgress, AdbCompression? compression}) async {
    final localStat = await local.stat();
    await write(
      remote,
      local.openRead(),
      permissions: localStat.mode & 0x1ff,
      modified: localStat.modified,
      size: localStat.size,
      onProgress: onProgress,
      compression: compression,
    );
  }

  /// Copies the device directory [remote] into [local] (created as needed), recursively. Links on the device are
  /// skipped. Returns the number of files copied. [compression] as in [AdbSync.read].
  Future<int> pullDirectory(String remote, Directory local, {AdbCompression? compression}) async {
    await local.create(recursive: true);
    var count = 0;
    for (final entry in await list(remote)) {
      final from = _join(remote, entry.name);
      if (Platform.isWindows && entry.name.contains(_windowsReserved)) {
        throw AdbSyncException('"${entry.name}" cannot be a file name on Windows', path: from);
      }
      final to = p.join(local.path, entry.name);
      if (entry.stat.isDirectory) {
        count += await pullDirectory(from, Directory(to), compression: compression);
      } else if (entry.stat.isFile) {
        await pullFile(from, File(to), compression: compression);
        count++;
      }
    }
    return count;
  }

  /// Copies [local] into the device directory [remote], recursively. Links are created as links (pointing where they
  /// point locally), not followed; pipes and sockets are skipped, as adb does. Empty directories are created too, so a
  /// tree pulled back with [pullDirectory] looks the same.
  ///
  /// With [onlyChanged], a file whose device copy has the same size and modification time (to the second) is skipped,
  /// like `adb sync`. Returns the number of files and links copied. [compression] as in [AdbSync.write]. Throws
  /// [AdbSyncException] when a directory cannot be made.
  Future<int> pushDirectory(
    Directory local,
    String remote, {
    bool onlyChanged = false,
    AdbCompression? compression,
  }) async {
    // `/t/` and `/t` name the same directory.
    final root = remote.length > 1 && remote.endsWith('/') ? remote.substring(0, remote.length - 1) : remote;
    final directories = [root];
    final transfers = <(FileSystemEntity, String)>[];
    // Remote directories that get something inside; the others are created explicitly.
    final filled = <String>{};
    await for (final entity in local.list(recursive: true, followLinks: false)) {
      final target = _join(root, _relative(entity, local));
      if (entity is Directory) {
        directories.add(target);
      } else if (entity is Link || (await entity.stat()).type == FileSystemEntityType.file) {
        transfers.add((entity, target));
      } else {
        continue; // A pipe or a socket: reading it would wait for a writer.
      }
      filled.add(_parent(target));
    }

    // Devices with shell protocol v2 but without `fixed_push_mkdir` (Android 7 to 9) fail to create the parents of a
    // pushed file (`secure_mkdirs failed`): make the whole tree first, as adb does. Elsewhere the device makes parents
    // itself, and only empty directories need making.
    final everything = !connection.supports(AdbFeature.fixedPushMkdir) && connection.supports(AdbFeature.shellV2);
    await _makeDirectories(everything ? directories : directories.where((d) => !filled.contains(d)).toList());

    var count = 0;
    for (final (entity, target) in transfers) {
      if (entity is Link) {
        await writeLink(target, await entity.target());
      } else {
        final file = entity as File;
        if (onlyChanged && await _sameAs(file, target)) continue;
        await pushFile(file, target, compression: compression);
      }
      count++;
    }
    return count;
  }

  /// Makes [directories] with `mkdir -p`, in batches under adb's limit for one command line.
  Future<void> _makeDirectories(List<String> directories) async {
    var batch = <String>[];
    var length = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      final result = await connection.shell.run('mkdir -p ${batch.map(shellQuote).join(' ')}');
      if ((result.exitCode ?? 0) != 0) {
        final output = '${result.stdoutText}${result.stderrText}'.trim();
        throw AdbSyncException('Cannot make directories: $output', path: batch.first);
      }
      batch = [];
      length = 0;
    }

    for (final dir in directories..sort((a, b) => a.length.compareTo(b.length))) {
      final quoted = shellQuote(dir).length + 1;
      if (length + quoted > 30000) await flush();
      batch.add(dir);
      length += quoted;
    }
    await flush();
  }

  /// The stat of what [remote] names, following a link where the device can.
  Future<AdbFileStat?> _target(String remote) => stat(remote, followLinks: canFollowLinks);

  Future<bool> _sameAs(File local, String remote) async {
    final AdbFileStat? device;
    try {
      device = await _target(remote);
    } on AdbSyncException {
      return false;
    }
    if (device == null || !device.isFile) return false;
    final mine = await local.stat();
    return device.size == mine.size &&
        device.modified.millisecondsSinceEpoch ~/ 1000 == mine.modified.millisecondsSinceEpoch ~/ 1000;
  }

  /// [entity]'s path under [root], with `/` separators.
  static String _relative(FileSystemEntity entity, Directory root) =>
      p.relative(entity.path, from: root.path).split(p.separator).join('/');

  /// Characters Android allows in file names and Windows does not (`\` would even split the name into folders).
  static final RegExp _windowsReserved = RegExp(r'[\\:*?"<>|\x00-\x1f]');

  static String _parent(String path) {
    final slash = path.lastIndexOf('/');
    return slash == 0 ? '/' : path.substring(0, slash);
  }

  static String _join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';
}
