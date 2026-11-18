// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/sync_protocol.dart';
import 'shell.dart';
import 'sync.dart';

/// Local files and directories with [AdbSync], like `adb pull` and `adb push`.
extension AdbSyncFiles on AdbSync {
  /// Copies the device file [remote] to [local], replacing it.
  ///
  /// The local file gets the device file's modification time. A failed transfer leaves no partial file behind.
  Future<void> pullFile(String remote, File local, {AdbProgress? onProgress}) async {
    final info = await _target(remote);
    final partial = File('${local.path}.${Random.secure().nextInt(1 << 32).toRadixString(16)}.part');
    final sink = partial.openWrite();
    try {
      await sink.addStream(read(remote, onProgress: (done, _) => onProgress?.call(done, info?.size)));
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
  /// to 9 the parent directory must exist ([pushDirectory] makes the tree).
  Future<void> pushFile(File local, String remote, {AdbProgress? onProgress}) async {
    final localStat = await local.stat();
    await write(
      remote,
      local.openRead(),
      permissions: localStat.mode & 0x1ff,
      modified: localStat.modified,
      size: localStat.size,
      onProgress: onProgress,
    );
  }

  /// Copies the device directory [remote] into [local] (created as needed), recursively. Links on the device are
  /// skipped. Returns the number of files copied.
  Future<int> pullDirectory(String remote, Directory local) async {
    await local.create(recursive: true);
    var count = 0;
    for (final entry in await list(remote)) {
      final from = _join(remote, entry.name);
      final to = p.join(local.path, entry.name);
      if (entry.stat.isDirectory) {
        count += await pullDirectory(from, Directory(to));
      } else if (entry.stat.isFile) {
        await pullFile(from, File(to));
        count++;
      }
    }
    return count;
  }

  /// Copies [local] into the device directory [remote], recursively; directories are created by the device as files
  /// land in them. Links are created as links (pointing where they point locally), not followed.
  ///
  /// With [onlyChanged], a file whose device copy has the same size and modification time (to the second) is skipped,
  /// like `adb sync`. Returns the number of files and links copied.
  Future<int> pushDirectory(Directory local, String remote, {bool onlyChanged = false}) async {
    var count = 0;
    await _makeDirectories(local, remote);
    await for (final entity in local.list(recursive: true, followLinks: false)) {
      final target = _join(remote, _relative(entity, local));
      if (entity is Link) {
        await writeLink(target, await entity.target());
        count++;
      } else if (entity is File) {
        if (onlyChanged && await _sameAs(entity, target)) continue;
        await pushFile(entity, target);
        count++;
      }
    }
    return count;
  }

  /// Devices with shell protocol v2 but without `fixed_push_mkdir` (Android 7 to 9) fail to create the parents of a
  /// pushed file (`secure_mkdirs failed`): make the tree first, as adb does. Failures are ignored (a directory that
  /// exists already).
  Future<void> _makeDirectories(Directory local, String remote) async {
    if (connection.supports(AdbFeature.fixedPushMkdir) || !connection.supports(AdbFeature.shellV2)) return;

    final dirs = [
      remote,
      await for (final entity in local.list(recursive: true, followLinks: false))
        if (entity is Directory) _join(remote, _relative(entity, local)),
    ]..sort((a, b) => a.length.compareTo(b.length));

    // Batches under adb's own limit for one command line.
    var batch = <String>[];
    var length = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      try {
        await connection.shell.run('mkdir -p ${batch.map(shellQuote).join(' ')}');
      } on Object {
        // An existing directory, say: the push itself tells what really fails.
      }
      batch = [];
      length = 0;
    }

    for (final dir in dirs) {
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

  static String _join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';
}
