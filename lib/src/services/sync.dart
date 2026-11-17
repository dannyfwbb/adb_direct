// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/sync_protocol.dart';
import '../stream/adb_stream.dart';
import '../stream/stream_reader.dart';

/// Called as a transfer progresses with the bytes done so far and the total
/// when known.
typedef AdbProgress = void Function(int done, int? total);

/// Files on the device: [AdbConnection.sync].
///
/// Uses the sync protocol (`adb push`, `adb pull`, `adb ls`). Operations run
/// one at a time on a sync session; several at once open several sessions.
/// An idle session is closed after a short while.
final class AdbSync {
  /// Creates the namespace for [_connection]; transfers that make no
  /// progress for [stallTimeout] fail.
  @internal
  AdbSync(this._connection, {required this.stallTimeout}) {
    unawaited(_connection.done.then((_) => _idleTimer?.cancel()));
  }

  final AdbConnection _connection;

  /// How long a transfer may make no progress before it fails with
  /// [AdbTimeoutException] (the connection stays up).
  final Duration stallTimeout;

  _SyncSession? _idle;
  Timer? _idleTimer;

  static const Duration _idleClose = Duration(seconds: 2);

  bool get _v2Stat => _connection.supports(AdbFeature.statV2);
  bool get _v2List => _connection.supports(AdbFeature.lsV2);
  bool get _v2Transfer => _connection.supports(AdbFeature.sendRecvV2);

  /// Whether [stat] can follow links (`stat_v2`, Android 8 and later).
  bool get canFollowLinks => _v2Stat;

  /// Information about [path], or null when it does not exist.
  ///
  /// With [followLinks] false (the default, like `lstat`) a link is
  /// described itself; with true its target is, which needs
  /// [canFollowLinks]. Devices without `stat_v2` (Android 7 and older)
  /// report sizes modulo 4 GiB and cannot tell a missing file from an
  /// unreadable one (both null).
  ///
  /// Throws [AdbSyncException] when the device refuses (permission denied,
  /// not a directory in the path, …).
  Future<AdbFileStat?> stat(String path, {bool followLinks = false}) async {
    if (followLinks && !_v2Stat) {
      throw const AdbNotSupportedException(
        'Following links in stat needs stat_v2 (Android 8 and later)',
      );
    }
    _checkPath(path);
    return _run((session) => session.stat(path, followLinks: followLinks));
  }

  /// The entries of the directory [path] (without `.` and `..`).
  ///
  /// A directory the device cannot read, or a path that is not one, gives
  /// an empty list (adbd answers so on every version); `stat` tells them
  /// apart. Entries the device can name but not describe are left out.
  Future<List<AdbDirectoryEntry>> list(String path) async {
    _checkPath(path);
    return _run((session) => session.list(path));
  }

  /// The content of the file [path], as it arrives.
  ///
  /// Throws [AdbSyncException] (for example permission denied) when the
  /// device refuses. Cancelling the subscription stops the transfer.
  Stream<Uint8List> read(String path, {AdbProgress? onProgress}) async* {
    _checkPath(path);
    final session = await _acquire();
    var clean = false;
    try {
      session.startRead(path, v2: _v2Transfer);
      var done = 0;
      while (true) {
        final chunk = await session.nextReadChunk(path);
        if (chunk == null) break;
        done += chunk.length;
        onProgress?.call(done, null);
        yield chunk;
      }
      clean = true;
    } finally {
      // A consumer that stopped early leaves the session mid-transfer.
      if (!clean) session.markDirty();
      _release(session);
    }
  }

  /// Reads the whole file [path] into memory.
  Future<Uint8List> readAll(String path) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in read(path)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Writes [data] to the file [path] on the device, replacing it.
  ///
  /// [permissions] are the file's mode bits (`0644` by default). adbd
  /// copies the owner's bits to group and others (`0644` becomes `0666`,
  /// `0755` becomes `0777`), as with `adb push`; only the owner's bits
  /// matter. [modified] sets its modification time (now when null; seconds
  /// from 1970 to 2106). [size], when given, is passed to [onProgress] as
  /// the total; progress counts bytes the device has acknowledged.
  ///
  /// Throws [AdbSyncException] when the device refuses (read-only file
  /// system, no space, permission denied) — as soon as it does, not after
  /// the whole file was sent. Fails if [data] fails; adbd then removes the
  /// partial file.
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int permissions = 0x1a4,
    DateTime? modified,
    int? size,
    AdbProgress? onProgress,
  }) async {
    final mode = 0x8000 | (permissions & 0xfff);
    _checkPath(_v2Transfer ? path : '$path,$mode');
    final mtime = _mtime(modified ?? DateTime.now());
    return _run(
      (session) => session.write(
        path,
        data,
        mode: mode,
        mtime: mtime,
        v2: _v2Transfer,
        size: size,
        onProgress: onProgress,
      ),
    );
  }

  /// Writes [bytes] to the file [path] on the device.
  Future<void> writeAll(
    String path,
    List<int> bytes, {
    int permissions = 0x1a4,
    DateTime? modified,
  }) => write(
    path,
    Stream.value(bytes),
    permissions: permissions,
    modified: modified,
    size: bytes.length,
  );

  /// Creates the symbolic link [path] pointing at [target], as `adb push`
  /// does for links.
  Future<void> writeLink(String path, String target, {DateTime? modified}) {
    final mode = 0xa000 | 0x1ff;
    _checkPath(_v2Transfer ? path : '$path,$mode');
    final mtime = _mtime(modified ?? DateTime.now());
    return _run(
      (session) => session.write(
        path,
        Stream.value(utf8.encode(target)),
        mode: mode,
        mtime: mtime,
        v2: _v2Transfer,
        size: null,
        onProgress: null,
      ),
    );
  }

  /// Closes the idle session, if any. Running operations are not affected.
  Future<void> close() async {
    _idleTimer?.cancel();
    final idle = _idle;
    _idle = null;
    await idle?.quit();
  }

  static void _checkPath(String path) {
    if (utf8.encode(path).length > SyncLimits.maxPath) {
      throw ArgumentError.value(
        path,
        'path',
        'longer than ${SyncLimits.maxPath} bytes',
      );
    }
  }

  static int _mtime(DateTime time) {
    final seconds = time.millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0 || seconds > 0xffffffff) {
      throw ArgumentError.value(
        time,
        'modified',
        'must be between 1970 and 2106 (the protocol stores 32-bit seconds)',
      );
    }
    return seconds;
  }

  Future<T> _run<T>(Future<T> Function(_SyncSession session) operation) async {
    final session = await _acquire();
    try {
      return await operation(session);
    } finally {
      _release(session);
    }
  }

  Future<_SyncSession> _acquire() async {
    final idle = _idle;
    if (idle != null && idle.isReusable) {
      _idle = null;
      _idleTimer?.cancel();
      return idle;
    }
    final stream = await _connection.open('sync:');
    return _SyncSession(
      stream,
      StreamReader(
        stream,
        clock: _connection.clock,
        stallTimeout: stallTimeout,
      ),
      clock: _connection.clock,
      stallTimeout: stallTimeout,
      v2Stat: _v2Stat,
      v2List: _v2List,
    );
  }

  void _release(_SyncSession session) {
    final reusable = session.isReusable;
    if (!reusable || _idle != null || _connection.isClosed) {
      unawaited(reusable ? session.quit() : session.abandon());
      return;
    }
    _idle = session;
    _idleTimer?.cancel();
    _idleTimer = _connection.clock.timer(_idleClose, () {
      if (identical(_idle, session)) {
        _idle = null;
        unawaited(session.quit());
      }
    });
  }
}

/// One `sync:` stream and its framing.
final class _SyncSession {
  _SyncSession(
    this._stream,
    this._reader, {
    required this.clock,
    required this.stallTimeout,
    required this.v2Stat,
    required this.v2List,
  });

  final AdbStream _stream;
  final StreamReader _reader;
  final AdbClock clock;
  final Duration stallTimeout;
  final bool v2Stat;
  final bool v2List;

  /// Longest file name accepted in a listing.
  static const int _maxName = 4096;

  /// Longest `FAIL` message accepted.
  static const int _maxFailMessage = 64 * 1024;

  // A request whose answer was not read completely leaves the session in
  // an unknown place; a FAIL makes adbd close it. Either way it is not
  // reused.
  bool _dirty = false;
  bool _broken = false;

  /// Whether the session can serve another request.
  bool get isReusable => !_dirty && !_broken && !_stream.isClosed;

  void markDirty() => _dirty = true;

  /// Runs [request] with the session marked dirty until it completes.
  Future<T> _exchange<T>(Future<T> Function() request) async {
    _dirty = true;
    final result = await request();
    _dirty = false;
    return result;
  }

  Future<AdbFileStat?> stat(String path, {required bool followLinks}) async {
    final request = SyncRequest.withPath(
      v2Stat ? (followLinks ? SyncId.stat2 : SyncId.lstat2) : SyncId.stat,
      path,
    );
    // The answer is read completely before an errno turns into an
    // exception, so the session stays reusable.
    final (stat, error) = await _exchange(() => _stat(request, followLinks));
    if (error == 0 || error == 2) return stat;
    throw AdbSyncException(
      'Cannot stat $path: ${errnoName(error)}',
      path: path,
    );
  }

  Future<(AdbFileStat?, int)> _stat(Uint8List request, bool followLinks) async {
    await _stream.write(request);
    if (v2Stat) {
      final answer = await _reader.readExactly(SyncLimits.stat2Length);
      final data = ByteData.sublistView(answer);
      _expectId(data, followLinks ? SyncId.stat2 : SyncId.lstat2);
      final error = data.getUint32(4, Endian.little);
      return (error == 0 ? AdbFileStat.fromV2(data, 8) : null, error);
    }
    final answer = await _reader.readExactly(SyncLimits.stat1Length);
    final data = ByteData.sublistView(answer);
    _expectId(data, SyncId.stat);
    final stat = AdbFileStat.fromV1(data, 4);
    return (stat.mode == 0 && stat.size == 0 ? null : stat, 0);
  }

  Future<List<AdbDirectoryEntry>> list(String path) {
    final request = SyncRequest.withPath(
      v2List ? SyncId.list2 : SyncId.list,
      path,
    );
    return _exchange(() => _list(request, path));
  }

  Future<List<AdbDirectoryEntry>> _list(Uint8List request, String path) async {
    final v2 = v2List;
    await _stream.write(request);
    final fixed = v2 ? SyncLimits.dent2Length : SyncLimits.dent1Length;
    final entries = <AdbDirectoryEntry>[];
    while (true) {
      // Read the id first: a FAIL is shorter than an entry.
      final start = await _reader.readExactly(8);
      final startData = ByteData.sublistView(start);
      final id = startData.getUint32(0, Endian.little);
      if (id == SyncId.fail) {
        throw await _failure(startData.getUint32(4, Endian.little), path);
      }
      final head = Uint8List(fixed)
        ..setRange(0, 8, start)
        ..setRange(8, fixed, await _reader.readExactly(fixed - 8));
      // DONE is padded to the size of an entry.
      if (id == SyncId.done) return entries;
      final data = ByteData.sublistView(head);
      _expectId(data, v2 ? SyncId.dent2 : SyncId.dent);
      final nameLength = data.getUint32(fixed - 4, Endian.little);
      if (nameLength > _maxName) {
        throw AdbProtocolException('Directory entry name of $nameLength B');
      }
      final name = utf8.decode(
        await _reader.readExactly(nameLength),
        allowMalformed: true,
      );
      // An entry the device could not lstat carries an errno: left out.
      if (v2 && data.getUint32(4, Endian.little) != 0) continue;
      if (name == '.' || name == '..') continue;
      entries.add(
        AdbDirectoryEntry(
          name,
          v2 ? AdbFileStat.fromV2(data, 8) : AdbFileStat.fromV1(data, 4),
        ),
      );
    }
  }

  void startRead(String path, {required bool v2}) {
    _dirty = true;
    final request = v2
        ? [
            ...SyncRequest.withPath(SyncId.recv2, path),
            ...SyncRequest.header(SyncId.recv2, 0),
          ]
        : SyncRequest.withPath(SyncId.recv, path);
    // A failure of this write surfaces through the reader.
    unawaited(_stream.write(request).catchError((Object _) {}));
  }

  /// The next chunk of a transfer started with [startRead], or null at its
  /// end.
  Future<Uint8List?> nextReadChunk(String path) async {
    final head = await _reader.readExactly(8);
    final data = ByteData.sublistView(head);
    final id = data.getUint32(0, Endian.little);
    final length = data.getUint32(4, Endian.little);
    if (id == SyncId.done) {
      _dirty = false;
      return null;
    }
    if (id == SyncId.fail) throw await _failure(length, path);
    _expectId(data, SyncId.data);
    if (length > SyncLimits.maxData) {
      throw AdbProtocolException('Sync DATA chunk of $length bytes');
    }
    return _reader.readExactly(length);
  }

  Future<void> write(
    String path,
    Stream<List<int>> data, {
    required int mode,
    required int mtime,
    required bool v2,
    required int? size,
    required AdbProgress? onProgress,
  }) => _exchange(() async {
    final watchdog = _PushWatchdog(
      clock: clock,
      timeout: stallTimeout,
      progress: () => _stream.acknowledgedBytes + _reader.received,
      onStall: _stream.close,
    );
    try {
      return await _write(path, data, mode, mtime, v2, size, onProgress);
    } on AdbException catch (e) {
      if (watchdog.stalled) {
        throw AdbTimeoutException(
          'The push to $path made no progress for $stallTimeout',
          cause: e,
        );
      }
      rethrow;
    } finally {
      watchdog.stop();
    }
  });

  Future<void> _write(
    String path,
    Stream<List<int>> data,
    int mode,
    int mtime,
    bool v2,
    int? size,
    AdbProgress? onProgress,
  ) async {
    final start = _stream.acknowledgedBytes;
    void progress() =>
        onProgress?.call(_stream.acknowledgedBytes - start, size);
    try {
      await _stream.write(
        v2
            ? [
                ...SyncRequest.withPath(SyncId.send2, path),
                ...SyncRequest.triple(SyncId.send2, mode, 0),
              ]
            : SyncRequest.withPath(SyncId.send, '$path,$mode'),
      );
      await for (final chunk in data) {
        for (var offset = 0; offset < chunk.length;) {
          // adbd answers a write error with FAIL at once and then drains
          // until DONE: stop sending as soon as anything comes back.
          if (_reader.buffered > 0) return await _finishEarly(path, mtime);
          final end = offset + SyncLimits.maxData < chunk.length
              ? offset + SyncLimits.maxData
              : chunk.length;
          final frame = Uint8List(8 + end - offset);
          ByteData.sublistView(frame)
            ..setUint32(0, SyncId.data, Endian.little)
            ..setUint32(4, end - offset, Endian.little);
          frame.setRange(8, frame.length, chunk, offset);
          await _stream.write(frame);
          offset = end;
          progress();
        }
      }
      await _stream.write(SyncRequest.header(SyncId.done, mtime));
    } on AdbClosedException {
      // The device may have refused and closed: its FAIL explains why.
      if (_reader.buffered >= 8) {
        throw await _pushError(path) ??
            AdbProtocolException('The device ended a push to $path early');
      }
      rethrow;
    }
    final error = await _pushError(path);
    progress();
    if (error != null) throw error;
  }

  /// The device answered before the end of the data: send DONE (adbd drains
  /// until it) and report its answer.
  Future<void> _finishEarly(String path, int mtime) async {
    await _stream.write(SyncRequest.header(SyncId.done, mtime));
    throw await _pushError(path) ??
        AdbProtocolException('The device accepted an unfinished push');
  }

  /// Reads the answer to a push: null for `OKAY`, the failure otherwise.
  Future<AdbException?> _pushError(String path) async {
    final head = await _reader.readExactly(8);
    final data = ByteData.sublistView(head);
    final id = data.getUint32(0, Endian.little);
    if (id == SyncId.okay) return null;
    if (id == SyncId.fail) {
      return _failure(data.getUint32(4, Endian.little), path);
    }
    return AdbProtocolException(
      'Unexpected sync answer ${SyncId.name(id)} to a push',
    );
  }

  Future<AdbSyncException> _failure(int length, String path) async {
    _broken = true;
    if (length > _maxFailMessage) {
      throw AdbProtocolException('Sync FAIL message of $length bytes');
    }
    final message = utf8.decode(
      await _reader.readExactly(length),
      allowMalformed: true,
    );
    return AdbSyncException(message, path: path);
  }

  void _expectId(ByteData data, int expected) {
    final id = data.getUint32(0, Endian.little);
    if (id != expected) {
      throw AdbProtocolException(
        'Expected sync ${SyncId.name(expected)}, got ${SyncId.name(id)}',
      );
    }
  }

  Future<void> quit() async {
    if (_stream.isClosed) return;
    try {
      await _stream.write(SyncRequest.header(SyncId.quit, 0));
    } on AdbException {
      // Closing anyway.
    }
    await abandon();
  }

  Future<void> abandon() async {
    await _reader.cancel();
    await _stream.close();
  }
}

/// Fails a push that makes no progress: no acknowledgement of our data and
/// no byte from the device for a whole period. Acknowledgements keep coming
/// while adbd drains its window to storage after our last write, so a slow
/// disk is progress, not a stall.
final class _PushWatchdog {
  _PushWatchdog({
    required this.clock,
    required this.timeout,
    required this.progress,
    required this.onStall,
  }) {
    _last = progress();
    _schedule();
  }

  final AdbClock clock;
  final Duration timeout;
  final int Function() progress;
  final void Function() onStall;
  late int _last;
  Timer? _timer;
  bool stalled = false;

  void _schedule() {
    _timer = clock.timer(timeout, () {
      final now = progress();
      if (now == _last) {
        stalled = true;
        onStall();
        return;
      }
      _last = now;
      _schedule();
    });
  }

  void stop() => _timer?.cancel();
}
