// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Sync protocol ids (adbd's `file_sync_protocol.h`), four ASCII letters as
/// a little-endian integer.
abstract final class SyncId {
  static int _id(String s) =>
      s.codeUnitAt(0) |
      (s.codeUnitAt(1) << 8) |
      (s.codeUnitAt(2) << 16) |
      (s.codeUnitAt(3) << 24);

  /// `STAT`: lstat, 32-bit fields.
  static final int stat = _id('STAT');

  /// `STA2`: stat (follows links), 64-bit fields and errno.
  static final int stat2 = _id('STA2');

  /// `LST2`: lstat, 64-bit fields and errno.
  static final int lstat2 = _id('LST2');

  /// `LIST`: directory listing, v1 entries.
  static final int list = _id('LIST');

  /// `LIS2`: directory listing, v2 entries.
  static final int list2 = _id('LIS2');

  /// `DENT`: a v1 directory entry.
  static final int dent = _id('DENT');

  /// `DNT2`: a v2 directory entry.
  static final int dent2 = _id('DNT2');

  /// `SEND`: push, v1.
  static final int send = _id('SEND');

  /// `SND2`: push, v2.
  static final int send2 = _id('SND2');

  /// `RECV`: pull, v1.
  static final int recv = _id('RECV');

  /// `RCV2`: pull, v2.
  static final int recv2 = _id('RCV2');

  /// `DONE`: end of a listing or a transfer.
  static final int done = _id('DONE');

  /// `DATA`: a chunk of file data.
  static final int data = _id('DATA');

  /// `OKAY`: a push succeeded.
  static final int okay = _id('OKAY');

  /// `FAIL`: an operation failed; a message follows.
  static final int fail = _id('FAIL');

  /// `QUIT`: leave sync mode.
  static final int quit = _id('QUIT');

  /// The four letters of [id].
  static String name(int id) => String.fromCharCodes([
    id & 0xff,
    (id >> 8) & 0xff,
    (id >> 16) & 0xff,
    (id >> 24) & 0xff,
  ]);
}

/// Limits of the sync protocol.
abstract final class SyncLimits {
  /// The largest `DATA` chunk.
  static const int maxData = 64 * 1024;

  /// The longest path adbd accepts.
  static const int maxPath = 1024;

  /// Size of a `sync_stat_v2` / the fixed part of `sync_dent_v2`.
  static const int stat2Length = 72;

  /// Size of `sync_stat_v1`.
  static const int stat1Length = 16;

  /// Size of the fixed part of `sync_dent_v1`.
  static const int dent1Length = 20;

  /// Size of the fixed part of `sync_dent_v2`.
  static const int dent2Length = 76;
}

/// Encodes sync requests.
abstract final class SyncRequest {
  /// `{id, length}` followed by [path] in UTF-8 (no NUL).
  static Uint8List withPath(int id, String path) {
    final bytes = utf8.encode(path);
    if (bytes.length > SyncLimits.maxPath) {
      throw ArgumentError.value(
        path,
        'path',
        'longer than ${SyncLimits.maxPath} bytes',
      );
    }
    return header(id, bytes.length, bytes);
  }

  /// `{id, value}` followed by [payload].
  static Uint8List header(int id, int value, [List<int> payload = const []]) {
    final out = Uint8List(8 + payload.length);
    ByteData.sublistView(out)
      ..setUint32(0, id, Endian.little)
      ..setUint32(4, value, Endian.little);
    out.setRange(8, out.length, payload);
    return out;
  }

  /// `{id, a, b}`: the second part of `SND2` (mode, flags).
  static Uint8List triple(int id, int a, int b) {
    final out = Uint8List(12);
    ByteData.sublistView(out)
      ..setUint32(0, id, Endian.little)
      ..setUint32(4, a, Endian.little)
      ..setUint32(8, b, Endian.little);
    return out;
  }
}

/// What a device knows about a file, from `STAT`, `STA2`, `LST2` or a
/// directory entry.
@immutable
final class AdbFileStat {
  /// Creates a stat.
  const AdbFileStat({
    required this.mode,
    required this.size,
    required this.modified,
    this.accessed,
    this.changed,
    this.uid,
    this.gid,
    this.links,
    this.device,
    this.inode,
  });

  /// Decodes a v1 `STAT` answer or `DENT` fields (mode, size, mtime).
  @internal
  factory AdbFileStat.fromV1(ByteData data, int offset) => AdbFileStat(
    mode: data.getUint32(offset, Endian.little),
    size: data.getUint32(offset + 4, Endian.little),
    modified: _time(data.getUint32(offset + 8, Endian.little)),
  );

  /// Decodes the fields of `sync_stat_v2` after `{id, error}`, at [offset].
  @internal
  factory AdbFileStat.fromV2(ByteData data, int offset) => AdbFileStat(
    device: data.getUint64(offset, Endian.little),
    inode: data.getUint64(offset + 8, Endian.little),
    mode: data.getUint32(offset + 16, Endian.little),
    links: data.getUint32(offset + 20, Endian.little),
    uid: data.getUint32(offset + 24, Endian.little),
    gid: data.getUint32(offset + 28, Endian.little),
    size: data.getUint64(offset + 32, Endian.little),
    accessed: _time(data.getInt64(offset + 40, Endian.little)),
    modified: _time(data.getInt64(offset + 48, Endian.little)),
    changed: _time(data.getInt64(offset + 56, Endian.little)),
  );

  /// POSIX mode: file type and permission bits.
  final int mode;

  /// Size in bytes. Wraps above 4 GiB on devices without `stat_v2`.
  final int size;

  /// Last modification.
  final DateTime modified;

  /// Last access (`stat_v2` only).
  final DateTime? accessed;

  /// Last status change (`stat_v2` only).
  final DateTime? changed;

  /// Owner (`stat_v2` only).
  final int? uid;

  /// Group (`stat_v2` only).
  final int? gid;

  /// Hard links (`stat_v2` only).
  final int? links;

  /// Device id (`stat_v2` only).
  final int? device;

  /// Inode (`stat_v2` only).
  final int? inode;

  /// The permission bits (`mode & 07777`).
  int get permissions => mode & 0xfff;

  /// Whether it is a regular file.
  bool get isFile => mode & _typeMask == 0x8000;

  /// Whether it is a directory.
  bool get isDirectory => mode & _typeMask == 0x4000;

  /// Whether it is a symbolic link (only from `LST2`, `STAT`, or listings).
  bool get isLink => mode & _typeMask == 0xa000;

  static const int _typeMask = 0xf000;

  static DateTime _time(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  @override
  bool operator ==(Object other) =>
      other is AdbFileStat &&
      other.mode == mode &&
      other.size == size &&
      other.modified == modified &&
      other.accessed == accessed &&
      other.changed == changed &&
      other.uid == uid &&
      other.gid == gid &&
      other.links == links &&
      other.device == device &&
      other.inode == inode;

  @override
  int get hashCode => Object.hash(
    mode,
    size,
    modified,
    accessed,
    changed,
    uid,
    gid,
    links,
    device,
    inode,
  );

  @override
  String toString() =>
      'AdbFileStat(mode ${mode.toRadixString(8)}, $size B, $modified)';
}

/// One entry of a directory listing.
@immutable
final class AdbDirectoryEntry {
  /// Creates an entry.
  const AdbDirectoryEntry(this.name, this.stat);

  /// The name within the directory (no path).
  final String name;

  /// Its stat (lstat semantics: links are not followed).
  final AdbFileStat stat;

  @override
  String toString() => 'AdbDirectoryEntry($name, $stat)';
}

/// Names of the errno values a device commonly reports.
String errnoName(int errno) => switch (errno) {
  1 => 'EPERM (operation not permitted)',
  2 => 'ENOENT (no such file or directory)',
  5 => 'EIO (I/O error)',
  13 => 'EACCES (permission denied)',
  17 => 'EEXIST (file exists)',
  20 => 'ENOTDIR (not a directory)',
  21 => 'EISDIR (is a directory)',
  28 => 'ENOSPC (no space left on device)',
  30 => 'EROFS (read-only file system)',
  36 => 'ENAMETOOLONG (file name too long)',
  40 => 'ELOOP (too many symbolic links)',
  _ => 'errno $errno',
};
