// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// The serving side of incremental installs, written from AOSP `packages/modules/adb/client/incremental.cpp`,
// `incremental_server.cpp` and `incremental_utils.cpp` (Apache-2.0): the install arguments, the request and block
// layouts, the verity tree arithmetic, and which blocks of an APK the package manager reads first.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../compression/lz4.dart';
import '../errors.dart';
import '../protocol/byte_queue.dart';
import '../stream/adb_stream.dart';

/// One file of an incremental install: an APK (or a `.dm` file) that the device reads block by block while the app is
/// already installed and starting.
@immutable
final class AdbIncrementalApk {
  /// A file named [name] of [size] bytes, read with [read].
  ///
  /// [signature] is the content of its APK Signature Scheme v4 file (`<apk>.idsig`, which `apksigner` writes next to
  /// the APK when v4 signing is on, as the Android Gradle plugin does for debug builds). A file without one is sent
  /// whole before the install starts, which takes away the speed-up. [close] is called once serving has ended.
  const AdbIncrementalApk({required this.name, required this.size, required this.read, this.signature, this.close});

  /// An APK on `dart:io`, with `<path>.idsig` as its signature when that file exists (or [signature]). The file stays
  /// open until serving ends.
  factory AdbIncrementalApk.file(File apk, {File? signature}) {
    final idsig = signature ?? File('${apk.path}.idsig');
    Future<RandomAccessFile>? open;
    return AdbIncrementalApk(
      name: apk.uri.pathSegments.last,
      size: apk.lengthSync(),
      read: (offset, length) async {
        final file = await (open ??= apk.open());
        await file.setPosition(offset);
        return file.read(length);
      },
      signature: idsig.existsSync() ? idsig.readAsBytesSync() : null,
      close: () async => (await open)?.close(),
    );
  }

  /// The name on the device; it must not contain `:`.
  final String name;

  /// Size in bytes.
  final int size;

  /// Reads a number of bytes at an offset (fewer only at the end of the file).
  final Future<Uint8List> Function(int offset, int length) read;

  /// The content of the `.idsig` file, or null.
  final Uint8List? signature;

  /// Releases what [read] holds, if anything.
  final Future<void> Function()? close;
}

/// An incremental install whose app is installed and whose remaining blocks are still being sent: the result of
/// `AdbPackages.installIncremental`.
///
/// The app can start before all its blocks have arrived; a block it needs that is not there yet is fetched at once.
/// Keep the connection open until [done] completes: an app whose blocks never all arrive stays incomplete, and the
/// device fails its reads of the missing parts.
final class AdbIncrementalInstall {
  AdbIncrementalInstall._(this._server);

  final IncrementalServer _server;

  /// What the package manager printed (`Success`).
  String get output => _server.output;

  /// Data blocks sent so far.
  int get blocksSent => _server.blocksSent;

  /// Data blocks of all files together.
  int get totalBlocks => _server.totalBlocks;

  /// Whether every block has been sent.
  bool get isComplete => _server.blocksSent == _server.totalBlocks;

  /// Completes when serving has ended: the device said it has every block (`SERVING_COMPLETE`), or closed the stream.
  /// Fails when the connection fails first or a file cannot be read.
  Future<void> get done => _server.done;

  /// Stops serving now. Blocks not sent by then are missing on the device until the app is installed again.
  Future<void> close() => _server.stop();

  @override
  String toString() => 'AdbIncrementalInstall($blocksSent/$totalBlocks blocks)';
}

/// Size of an incremental block and of a verity tree block.
const int _blockSize = 4096;

/// SHA-256 digests per tree block.
const int _hashesPerBlock = _blockSize ~/ 32;

/// Largest v4 signature the device accepts (incrementalfs.h).
const int _maxSignature = 8096;

/// The number of verity tree blocks for a file of [size] bytes (the leaf level last, the root not stored).
@internal
int verityTreeBlocks(int size) {
  if (size == 0) return 0;
  var total = 0;
  var level = (size + _blockSize - 1) ~/ _blockSize;
  while (level > 1) {
    level = (level + _hashesPerBlock - 1) ~/ _hashesPerBlock;
    total += level;
  }
  return total;
}

/// What an `.idsig` file holds: the part sent as the install argument, and where its verity tree is.
@internal
typedef IdsigParts = ({Uint8List header, int treeOffset, int treeSize});

/// Splits an `.idsig` file: version (4 bytes), hashing info and signing info (each a little-endian 32-bit size and its
/// bytes), the tree size (4 bytes), the tree. The header is everything before the tree size.
///
/// Throws [FormatException] for a malformed file, a header past 8096 bytes, or a tree that does not fit a file of
/// [fileSize] bytes.
@internal
IdsigParts parseIdsig(Uint8List idsig, int fileSize) {
  final data = ByteData.sublistView(idsig);
  var offset = 4;
  for (var i = 0; i < 2; i++) {
    if (offset + 4 > idsig.length) throw const FormatException('The .idsig file is truncated');
    final length = data.getInt32(offset, Endian.little);
    if (length < 0 || offset + 4 + length > idsig.length) throw const FormatException('The .idsig file is truncated');
    offset += 4 + length;
  }
  if (offset > _maxSignature) {
    throw FormatException('The v4 signature has $offset bytes; the device takes $_maxSignature');
  }
  if (offset + 4 > idsig.length) throw const FormatException('The .idsig file is truncated');
  final treeSize = data.getInt32(offset, Endian.little);
  final expected = verityTreeBlocks(fileSize) * _blockSize;
  if (treeSize != expected) {
    throw FormatException('The .idsig verity tree has $treeSize bytes; a file of $fileSize bytes needs $expected');
  }
  if (offset + 4 + treeSize > idsig.length) throw const FormatException('The .idsig verity tree is truncated');
  return (header: Uint8List.sublistView(idsig, 0, offset), treeOffset: offset + 4, treeSize: treeSize);
}

/// The blocks of an APK the package manager reads first, in order: the last 64 KiB and the rest of the APK signing
/// block, central directory and end record; block 0; then `AndroidManifest.xml`, `resources.arsc`, native libraries
/// whole and the head of `classes.dex`. Empty for a file that is not a signed zip.
@internal
Future<List<int>> apkPriorityBlocks(Future<Uint8List> Function(int offset, int length) read, int size) async {
  final tail = size < 0x10000 + 22 ? size : 0x10000 + 22;
  final end = await read(size - tail, tail);
  final endData = ByteData.sublistView(end);
  var eocd = -1;
  for (var i = end.length - 22; i >= 0; i--) {
    if (endData.getUint32(i, Endian.little) == 0x06054b50 &&
        endData.getUint16(i + 20, Endian.little) == end.length - 22 - i) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return const [];
  final directorySize = endData.getUint32(eocd + 12, Endian.little);
  final directoryOffset = endData.getUint32(eocd + 16, Endian.little);
  if (directoryOffset < 32 || directoryOffset + directorySize > size) return const [];

  // The APK signing block ends right before the central directory with a size and the magic "APK Sig Block 42".
  final footer = ByteData.sublistView(await read(directoryOffset - 24, 24));
  if (footer.getUint64(8, Endian.little) != 0x20676953204b5041 ||
      footer.getUint64(16, Endian.little) != 0x3234206b636f6c42) {
    return const [];
  }
  final signerSize = footer.getUint64(0, Endian.little);
  final signerOffset = directoryOffset - signerSize - 8;
  if (signerOffset < 0) return const [];

  final blocks = <int>[];
  void range(int first, int count) {
    for (var i = 0; i < count; i++) {
      blocks.add(first + i);
    }
  }

  final signerBlock = signerOffset ~/ _blockSize;
  final lastBlock = size ~/ _blockSize;
  final count = lastBlock - signerBlock + 1;
  // Zip readers look for the end record in the last 64 KiB first.
  const searched = 0x10000 ~/ _blockSize + 1;
  if (count > searched) {
    range(lastBlock - searched + 1, searched);
    range(signerBlock, count - searched);
  } else {
    range(signerBlock, count);
  }
  range(0, 1);

  final directory = ByteData.sublistView(await read(directoryOffset, directorySize));
  for (var at = 0; at + 46 <= directory.lengthInBytes;) {
    if (directory.getUint32(at, Endian.little) != 0x02014b50) break;
    final method = directory.getUint16(at + 10, Endian.little);
    final flags = directory.getUint16(at + 8, Endian.little);
    final compressed = directory.getUint32(at + 20, Endian.little);
    final uncompressed = directory.getUint32(at + 24, Endian.little);
    final nameLength = directory.getUint16(at + 28, Endian.little);
    final extraLength = directory.getUint16(at + 30, Endian.little);
    final commentLength = directory.getUint16(at + 32, Endian.little);
    final localHeader = directory.getUint32(at + 42, Endian.little);
    if (at + 46 + nameLength > directory.lengthInBytes) break;
    final name = utf8.decode(Uint8List.sublistView(directory, at + 46, at + 46 + nameLength), allowMalformed: true);
    at += 46 + nameLength + extraLength + commentLength;

    final wanted =
        name == 'AndroidManifest.xml' ||
        name == 'resources.arsc' ||
        name == 'classes.dex' ||
        (name.startsWith('lib/') && name.endsWith('.so'));
    if (!wanted || localHeader + 30 > size) continue;
    final local = ByteData.sublistView(await read(localHeader, 30));
    if (local.getUint32(0, Endian.little) != 0x04034b50) continue;
    final dataOffset = localHeader + 30 + local.getUint16(26, Endian.little) + local.getUint16(28, Endian.little);
    final first = dataOffset ~/ _blockSize;
    if (name == 'classes.dex') {
      // Only its head is read while installing.
      range(first, 2);
    } else {
      final length = (method == 0 ? uncompressed : compressed) + (flags & 0x08 != 0 ? 16 : 0);
      range(first, (dataOffset + length) ~/ _blockSize - first + 1);
    }
  }
  final seen = <int>{};
  return [
    for (final block in blocks)
      if (block >= 0 && block * _blockSize < size && seen.add(block)) block,
  ];
}

/// The argument naming a file in `install-incremental`: `name:size:id:signature:1` for a signed file (the signature
/// header in base64, protocol version 1), `name:size:id` for one sent through stdin.
@internal
String incrementalArgument(String name, int size, int id, Uint8List? signatureHeader) =>
    signatureHeader == null ? '$name:$size:$id' : '$name:$size:$id:${base64.encode(signatureHeader)}:1';

/// Request types the device sends, each after the magic `INCR`.
abstract final class _Request {
  static const int servingComplete = 0;
  static const int blockMissing = 1;
  static const int prefetch = 2;
  static const int destroy = 3;
}

/// One signed file being served.
final class _ServedFile {
  _ServedFile(this.apk, this.id, IdsigParts parts)
    : treeOffset = parts.treeOffset,
      treeBlocks = parts.treeSize ~/ _blockSize,
      blockCount = (apk.size + _blockSize - 1) ~/ _blockSize {
    sent = List.filled(blockCount, false);
    treeSent = List.filled(treeBlocks, false);
  }

  final AdbIncrementalApk apk;
  final int id;
  final int treeOffset;
  final int treeBlocks;
  final int blockCount;
  late final List<bool> sent;
  late final List<bool> treeSent;
  int sentCount = 0;
  List<int> priority = const [];
  bool prefetchRequested = false;
}

/// A prefetch in progress: the file's priority blocks, then [next] to [end].
final class _Prefetch {
  _Prefetch(this.file, this.next, this.end);

  final _ServedFile file;
  int next;
  final int end;
  int priorityIndex = 0;

  bool get isDone => next >= end && priorityIndex >= file.priority.length;
}

/// Serves the blocks of signed files over the `install-incremental` stream, and watches the package manager's output
/// that is mixed into it.
@internal
final class IncrementalServer {
  /// Serves the signed files (in file id order) over the stream.
  IncrementalServer(this._stream, List<(AdbIncrementalApk, IdsigParts)> files, this._release)
    : _files = [for (final (i, (apk, parts)) in files.indexed) _ServedFile(apk, i, parts)];

  final AdbStream _stream;
  final List<_ServedFile> _files;
  final Future<void> Function() _release;

  final ByteQueue _incoming = ByteQueue();
  final StringBuffer _output = StringBuffer();
  final Queue<_Prefetch> _prefetches = Queue<_Prefetch>();
  final Queue<(int, int)> _missing = Queue<(int, int)>();

  final Completer<String> _installed = Completer<String>();
  final Completer<void> _done = Completer<void>();
  Completer<void>? _wake;
  StreamSubscription<Uint8List>? _subscription;

  /// Serving was stopped here, or the stream ended.
  bool _stopped = false;

  /// The stream ended (closed by the device or failed).
  bool _streamEnded = false;
  bool _doneSent = false;

  /// The device needs nothing more. Its answer may still be on the way: serving ends once it has arrived.
  bool _deviceDone = false;

  bool get _finished => _stopped || (_installed.isCompleted && (_deviceDone || _files.isEmpty));

  final BytesBuilder _pending = BytesBuilder(copy: false);

  static final Uint8List _magic = ascii.encode('INCR');

  /// Pending blocks are sent once they pass this size (31 blocks, as adb does).
  static const int _flushSize = 31 * _blockSize;

  /// Blocks sent per prefetch round before requests are looked at again.
  static const int _prefetchRound = 128;

  /// What the package manager printed so far.
  String get output => _output.toString();

  int get blocksSent => _files.fold(0, (sum, f) => sum + f.sentCount);

  int get totalBlocks => _files.fold(0, (sum, f) => sum + f.blockCount);

  Future<void> get done => _done.future;

  /// Completes with the package manager's output once it said `Success`; fails with [AdbInstallException] when it says
  /// `Failure [...]`, or with the stream's failure.
  Future<String> get installed => _installed.future;

  /// Starts serving: the greeting, then requests as they come.
  Future<void> start() async {
    _done.future.ignore();
    _installed.future.ignore();
    for (final file in _files) {
      if (!file.apk.name.toLowerCase().endsWith('.apk')) continue;
      try {
        file.priority = await apkPriorityBlocks(file.apk.read, file.apk.size);
      } on Object {
        // Only an optimization: the device asks for what it misses.
      }
    }
    _subscription = _stream.input.listen(_onData, onDone: _onClosed, onError: (Object _) => _onClosed());
    unawaited(_serve());
  }

  /// Stops serving and closes the stream.
  Future<void> stop() async {
    _stopped = true;
    _poke();
    await _stream.close();
    await done.catchError((Object _) {});
  }

  void _onData(Uint8List data) {
    _incoming.add(data);
    while (true) {
      final at = _findMagic();
      if (at < 0) {
        // Everything but a possible start of the magic is the package manager's output.
        _addOutput(_incoming.take(_incoming.length - _magicPrefixAtEnd()));
        break;
      }
      _addOutput(_incoming.take(at));
      if (_incoming.length < 12) break;
      _incoming.skip(4);
      final request = ByteData.sublistView(_incoming.take(8));
      _onRequest(request.getInt16(0), request.getInt16(2), request.getInt32(4));
    }
    _poke();
  }

  /// Where the magic starts in [_incoming], or -1.
  int _findMagic() {
    for (var i = 0; i + 4 <= _incoming.length; i++) {
      if (_incoming.byteAt(i) == _magic[0] &&
          _incoming.byteAt(i + 1) == _magic[1] &&
          _incoming.byteAt(i + 2) == _magic[2] &&
          _incoming.byteAt(i + 3) == _magic[3]) {
        return i;
      }
    }
    return -1;
  }

  /// How many bytes at the end of [_incoming] could start the magic.
  int _magicPrefixAtEnd() {
    for (var keep = 3; keep > 0; keep--) {
      if (_incoming.length < keep) continue;
      var matches = true;
      for (var i = 0; i < keep && matches; i++) {
        matches = _incoming.byteAt(_incoming.length - keep + i) == _magic[i];
      }
      if (matches) return keep;
    }
    return 0;
  }

  void _addOutput(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _output.write(utf8.decode(bytes, allowMalformed: true));
    if (_installed.isCompleted) return;
    final text = _output.toString();
    if (text.contains('Success')) {
      _installed.complete(text);
    } else if (RegExp(r'Failure \[[^\]]*\]').hasMatch(text)) {
      final code = RegExp(r'Failure \[([A-Z0-9_]+)').firstMatch(text)?.group(1);
      _installed.completeError(
        AdbInstallException('Could not install incrementally: ${text.trim()}', failureCode: code, output: text),
      );
    }
  }

  void _onRequest(int type, int fileId, int block) {
    switch (type) {
      // The device has every block (it says so once loading reached 100%), or wants serving to end: adb then keeps
      // the stream open until the device closes it or 5 minutes pass; nothing more is asked for, so serving ends.
      case _Request.servingComplete || _Request.destroy:
        _deviceDone = true;
      case _Request.blockMissing:
        if (fileId >= 0 && fileId < _files.length && block >= 0 && block < _files[fileId].blockCount) {
          _missing.add((fileId, block));
        }
      case _Request.prefetch:
        if (fileId >= 0 && fileId < _files.length && !_files[fileId].prefetchRequested) {
          final file = _files[fileId]..prefetchRequested = true;
          _prefetches.add(_Prefetch(file, 0, file.blockCount));
        }
    }
  }

  void _onClosed() {
    _stopped = true;
    _streamEnded = true;
    if (!_installed.isCompleted) {
      _installed.completeError(
        _stream.closeReason ??
            AdbInstallException(
              'The device ended the incremental install without an answer: ${output.trim()}',
              output: output,
            ),
      );
    }
    _poke();
  }

  void _poke() {
    final wake = _wake;
    _wake = null;
    wake?.complete();
  }

  Future<void> _serve() async {
    try {
      await _stream.write(ascii.encode('OKAY'));
      while (!_finished) {
        if (!_doneSent && _prefetches.isEmpty && _missing.isEmpty && blocksSent == totalBlocks) {
          // Every block is there: a header with file id -1 says so.
          _pending.add(_header(-1, 0, 0, 0, 0));
          await _flush();
          _doneSent = true;
        }
        if (_missing.isNotEmpty) {
          final (fileId, block) = _missing.removeFirst();
          if (await _sendDataBlock(_files[fileId], block)) {
            await _flush();
            // The reader probably wants what follows too.
            _prefetches.addFirst(
              _Prefetch(_files[fileId], block + 1, _min(block + 8, _files[fileId].blockCount))
                ..priorityIndex = _files[fileId].priority.length,
            );
          }
          continue;
        }
        if (_prefetches.isNotEmpty) {
          await _prefetchRoundOnce();
          continue;
        }
        // Armed before the flush: news that arrives meanwhile completes it, so the wait below returns at once.
        final wake = _wake = Completer<void>();
        await _flush();
        await wake.future;
      }
      if (_pending.isNotEmpty && !_stream.isClosed) await _flush();
      if (_streamEnded && !_deviceDone && blocksSent < totalBlocks) {
        // The device went away before it had everything: the app is incomplete.
        throw _stream.closeReason ??
            AdbClosedException('The device closed the incremental install after $blocksSent of $totalBlocks blocks');
      }
      if (!_done.isCompleted) _done.complete();
    } on Object catch (e, stackTrace) {
      if (!_installed.isCompleted) _installed.completeError(e, stackTrace);
      if (!_done.isCompleted) {
        // A stream closed by the device after it had everything is the normal end.
        if (_deviceDone || (e is AdbClosedException && _doneSent && blocksSent == totalBlocks)) {
          _done.complete();
        } else {
          _done.completeError(e, stackTrace);
        }
      }
    } finally {
      await _subscription?.cancel();
      if (!_stream.isClosed) await _stream.close();
      await _release();
    }
  }

  Future<void> _prefetchRoundOnce() async {
    var budget = _prefetchRound;
    while (_prefetches.isNotEmpty && budget > 0 && _missing.isEmpty && !_finished) {
      final prefetch = _prefetches.first;
      final priority = prefetch.file.priority;
      while (budget > 0 && prefetch.priorityIndex < priority.length) {
        if (await _sendDataBlock(prefetch.file, priority[prefetch.priorityIndex++])) budget--;
      }
      while (budget > 0 && prefetch.next < prefetch.end) {
        if (await _sendDataBlock(prefetch.file, prefetch.next++)) budget--;
      }
      if (prefetch.isDone) _prefetches.removeFirst();
    }
  }

  /// Queues [block] of [file] with the tree blocks needed to verify it; false when it was sent before.
  Future<bool> _sendDataBlock(_ServedFile file, int block) async {
    if (block >= file.blockCount || file.sent[block]) return false;
    await _sendTreeBlocks(file, block);
    final data = await file.apk.read(block * _blockSize, _min(_blockSize, file.apk.size - block * _blockSize));
    final compressed = Lz4.compressBlock(data);
    // Stored when compression saves less than 5%.
    final useLz4 = compressed.length < _blockSize * 95 ~/ 100 && compressed.length < data.length;
    final payload = useLz4 ? compressed : data;
    _pending
      ..add(_header(file.id, 0, useLz4 ? 1 : 0, block, payload.length))
      ..add(payload);
    file.sent[block] = true;
    file.sentCount++;
    if (_pending.length > _flushSize) await _flush();
    return true;
  }

  /// The leaf of the verity tree that covers [block], and the levels above the leaves (all of them, the first time).
  Future<void> _sendTreeBlocks(_ServedFile file, int block) async {
    if (file.treeBlocks == 0) return;
    final leaves = (file.blockCount + _hashesPerBlock - 1) ~/ _hashesPerBlock;
    final firstLeaf = file.treeBlocks - leaves;
    final leaf = firstLeaf + block ~/ _hashesPerBlock;
    if (file.treeSent[leaf]) return;
    await _sendTreeBlock(file, leaf);
    if (firstLeaf == 0 || file.treeSent[0]) return;
    for (var i = 0; i < firstLeaf; i++) {
      await _sendTreeBlock(file, i);
    }
  }

  Future<void> _sendTreeBlock(_ServedFile file, int index) async {
    final signature = file.apk.signature!;
    final start = file.treeOffset + index * _blockSize;
    _pending
      ..add(_header(file.id, 1, 0, index, _blockSize))
      ..add(Uint8List.sublistView(signature, start, start + _blockSize));
    file.treeSent[index] = true;
  }

  /// A response chunk: its size (big-endian) and the blocks.
  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final blocks = _pending.takeBytes();
    final chunk = Uint8List(4 + blocks.length)
      ..buffer.asByteData().setInt32(0, blocks.length)
      ..setRange(4, 4 + blocks.length, blocks);
    await _stream.write(chunk);
  }

  /// Block header: file id, type (0 data, 1 tree), compression (0 none, 1 LZ4), block index, size; big-endian.
  static Uint8List _header(int fileId, int type, int compression, int block, int size) {
    final header = ByteData(10)
      ..setInt16(0, fileId)
      ..setInt8(2, type)
      ..setInt8(3, compression)
      ..setInt32(4, block)
      ..setInt16(8, size);
    return header.buffer.asUint8List();
  }

  static int _min(int a, int b) => a < b ? a : b;
}

/// Starts serving, and waits until the package manager has answered.
@internal
Future<AdbIncrementalInstall> serveIncremental(
  AdbStream stream,
  List<(AdbIncrementalApk, IdsigParts)> signed,
  Future<void> Function() release, {
  required AdbClock clock,
  required Duration answerTimeout,
}) async {
  final server = IncrementalServer(stream, signed, release);
  await server.start();
  try {
    await clock.deadline(
      server.installed,
      answerTimeout,
      () => AdbTimeoutException('The package manager did not answer the incremental install within $answerTimeout'),
    );
  } on Object {
    await server.stop();
    rethrow;
  }
  return AdbIncrementalInstall._(server);
}
