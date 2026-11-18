// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/byte_queue.dart';
import '../stream/adb_stream.dart';
import 'answers.dart';
import 'shell.dart';
import 'sync_files.dart';

/// A process the device reports through `track-app` (Android 12+).
@immutable
final class AdbAppProcess {
  /// Creates one.
  const AdbAppProcess({
    required this.pid,
    required this.debuggable,
    required this.profileable,
    required this.architecture,
    this.userId,
    this.processName,
    this.packageNames = const [],
    this.waitingForDebugger,
    this.uid,
  });

  /// The process id.
  final int pid;

  /// Whether a debugger may attach (`jdwp:<pid>`).
  final bool debuggable;

  /// Whether it can be profiled.
  final bool profileable;

  /// Its instruction set (`arm64`, `x86_64`, …).
  final String architecture;

  /// The Android user it runs as, when the device says.
  final int? userId;

  /// The process name, when the device says.
  final String? processName;

  /// The packages running in it.
  final List<String> packageNames;

  /// Whether it waits for a debugger, when the device says.
  final bool? waitingForDebugger;

  /// Its Linux uid, when the device says.
  final int? uid;

  @override
  String toString() =>
      'AdbAppProcess($pid${processName == null ? '' : ' $processName'}'
      '${debuggable ? ', debuggable' : ''})';
}

/// The progress of a bug report: [done] of [total] steps.
typedef AdbBugReportProgress = void Function(int done, int total);

/// Debugging services: JDWP, process tracking, logcat, screenshots and bug reports.
final class AdbDebug {
  /// Creates the namespace.
  @internal
  AdbDebug(this._connection);

  final AdbConnection _connection;

  /// A stream to the JDWP agent of [pid] (a debuggable process): the debugger's side of the wire, starting with the
  /// `JDWP-Handshake`.
  Future<AdbStream> jdwp(int pid) => _connection.open('jdwp:$pid');

  /// The pids of debuggable processes: a new list each time it changes, starting with the current one. Never ends by
  /// itself; cancel the subscription to stop.
  Stream<List<int>> trackJdwp() => _frames('track-jdwp').map(
    (frame) => [for (final line in utf8.decode(frame, allowMalformed: true).split('\n')) ?int.tryParse(line.trim())],
  );

  /// The app processes (Android 12+, feature `track_app`): a new list each time it changes, starting with the current
  /// one. Throws [AdbNotSupportedException] on older devices.
  Stream<List<AdbAppProcess>> trackApps() {
    if (!_connection.supports(AdbFeature.trackApp)) {
      return Stream.error(const AdbNotSupportedException('The device cannot track app processes (Android 12+)'));
    }
    return _frames('track-app').map(decodeAppProcesses);
  }

  /// The device log as lines (`logcat` with [arguments], for example `['-v', 'threadtime', '*:W']`). Without `-d` it
  /// follows the log until the subscription is cancelled.
  Stream<String> logcat({List<String> arguments = const []}) async* {
    // The PTY of old devices ends lines with CR LF, which the line splitter takes as one break.
    final (stream, _) = await _connection.shell.openRaw(['logcat', ...arguments].map(shellQuote).join(' '));
    try {
      yield* _lines(stream);
    } finally {
      await stream.close();
    }
  }

  /// A screenshot as PNG (`screencap -p`).
  Future<Uint8List> screencap({int? display}) async {
    final command = 'screencap -p${display == null ? '' : ' -d $display'}';
    Uint8List bytes;
    try {
      final stream = await _connection.open('exec:$command');
      final png = BytesBuilder(copy: false);
      await stream.input.forEach(png.add);
      bytes = png.takeBytes();
    } on AdbServiceUnavailableException {
      // Before Android 5 there is no exec:, and a PTY would mangle the bytes: write a file on the device and copy it.
      bytes = await _screencapToFile(command);
    }
    const signature = [0x89, 0x50, 0x4e, 0x47];
    if (bytes.length < 8 || Iterable<int>.generate(4).any((i) => bytes[i] != signature[i])) {
      final text = utf8.decode(bytes.take(200).toList(), allowMalformed: true);
      throw AdbProtocolException('screencap did not return a PNG: $text');
    }
    return bytes;
  }

  Future<Uint8List> _screencapToFile(String command) async {
    final path = '/data/local/tmp/adb_direct_${DateTime.now().microsecondsSinceEpoch}.png';
    try {
      await _connection.shell.run('$command ${shellQuote(path)}');
      return await _connection.sync.readAll(path);
    } finally {
      await _connection.shell.removeQuietly(path);
    }
  }

  /// Writes a bug report (a zip, Android 7+) to [local], as `adb bugreport` does: `bugreportz -p` on the device, then a
  /// pull, then the device copy is removed. Takes minutes; [onProgress] follows it.
  ///
  /// Throws [AdbException] when the device reports a failure.
  Future<void> bugreport(File local, {AdbBugReportProgress? onProgress}) async {
    final AdbStream stream;
    try {
      stream = await _connection.open('exec:bugreportz -p');
    } on AdbServiceUnavailableException {
      throw const AdbNotSupportedException('Bug reports as zip files need Android 7 or later');
    }

    String? path;
    await for (final line in _lines(stream)) {
      switch (BugreportLine.parse(line)) {
        case BugreportProgress(:final done, :final total):
          onProgress?.call(done, total);
        case BugreportDone(path: final written):
          path = written;
        case BugreportFailed(:final reason):
          throw AdbServiceUnavailableException('The bug report failed: $reason', service: 'bugreportz');
        case null:
          break;
      }
    }
    if (path == null) throw const AdbProtocolException('bugreportz gave no file');

    try {
      await _connection.sync.pullFile(path, local);
    } finally {
      await _connection.shell.removeQuietly(path);
    }
  }

  static Stream<String> _lines(AdbStream stream) =>
      const Utf8Decoder(allowMalformed: true).bind(stream.input).transform(const LineSplitter());

  /// The payloads of a `<hex4 length><payload>` stream, however the bytes are split into messages.
  Stream<Uint8List> _frames(String service) async* {
    final stream = await _connection.open(service);
    final buffer = ByteQueue();
    int? want;
    try {
      await for (final chunk in stream.input) {
        buffer.add(chunk);
        while (true) {
          if (want == null) {
            if (buffer.length < 4) break;
            want = parseHex4(ascii.decode(buffer.take(4), allowInvalid: true));
            if (want == null) throw AdbProtocolException('A bad frame length on "$service"');
          }
          if (buffer.length < want) break;
          yield buffer.take(want);
          want = null;
        }
      }
    } finally {
      await stream.close();
    }
  }
}

/// One meaningful line of `bugreportz -p`.
@internal
sealed class BugreportLine {
  const BugreportLine();

  /// `PROGRESS:done/total`, `OK:path` or `FAIL:reason`; null for anything else.
  static BugreportLine? parse(String line) {
    final text = line.trim();
    if (text.startsWith('OK:')) return BugreportDone(text.substring(3));
    if (text.startsWith('FAIL:')) return BugreportFailed(text.substring(5));
    if (RegExp(r'^PROGRESS:(\d+)/(\d+)$').firstMatch(text) case final m?) {
      return BugreportProgress(int.parse(m[1]!), int.parse(m[2]!));
    }
    return null;
  }
}

/// `PROGRESS:done/total`.
@internal
final class BugreportProgress extends BugreportLine {
  /// Creates one.
  const BugreportProgress(this.done, this.total);

  /// Steps done.
  final int done;

  /// Steps in all.
  final int total;
}

/// `OK:path`: the zip on the device.
@internal
final class BugreportDone extends BugreportLine {
  /// Creates one.
  const BugreportDone(this.path);

  /// Where the zip is.
  final String path;
}

/// `FAIL:reason`.
@internal
final class BugreportFailed extends BugreportLine {
  /// Creates one.
  const BugreportFailed(this.reason);

  /// What the device said.
  final String reason;
}

/// Decodes an `AppProcesses` protobuf (`adb/proto/app_processes.proto`) with a minimal reader: varints and
/// length-delimited fields only, as the message has; unknown fields are skipped.
@internal
List<AdbAppProcess> decodeAppProcesses(Uint8List bytes) {
  final processes = <AdbAppProcess>[];
  final top = _ProtoReader(bytes);
  while (!top.atEnd) {
    final (field, wire) = top.tag();
    if (field == 1 && wire == 2) {
      processes.add(_decodeProcess(top.bytes()));
    } else {
      top.skip(wire);
    }
  }
  return processes;
}

AdbAppProcess _decodeProcess(Uint8List bytes) {
  var pid = 0;
  var debuggable = false;
  var profileable = false;
  var architecture = '';
  int? userId;
  String? processName;
  final packages = <String>[];
  bool? waiting;
  int? uid;
  final r = _ProtoReader(bytes);
  while (!r.atEnd) {
    final (field, wire) = r.tag();
    switch ((field, wire)) {
      case (1, 0):
        pid = r.varint();
      case (2, 0):
        debuggable = r.varint() != 0;
      case (3, 0):
        profileable = r.varint() != 0;
      case (4, 2):
        architecture = utf8.decode(r.bytes(), allowMalformed: true);
      case (5, 0):
        userId = r.varint();
      case (6, 2):
        processName = utf8.decode(r.bytes(), allowMalformed: true);
      case (7, 2):
        packages.add(utf8.decode(r.bytes(), allowMalformed: true));
      case (8, 0):
        waiting = r.varint() != 0;
      case (9, 0):
        uid = r.varint();
      default:
        r.skip(wire);
    }
  }
  return AdbAppProcess(
    pid: pid,
    debuggable: debuggable,
    profileable: profileable,
    architecture: architecture,
    userId: userId,
    processName: processName,
    packageNames: packages,
    waitingForDebugger: waiting,
    uid: uid,
  );
}

final class _ProtoReader {
  _ProtoReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get atEnd => _offset >= _bytes.length;

  (int, int) tag() {
    final key = varint();
    return (key >> 3, key & 7);
  }

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _bytes.length || shift > 63) throw const AdbProtocolException('A truncated protobuf varint');
      final b = _bytes[_offset++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final length = varint();
    if (length < 0 || _offset + length > _bytes.length) throw const AdbProtocolException('A truncated protobuf field');
    final out = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _offset += 8;
      case 2:
        bytes();
      case 5:
        _offset += 4;
      default:
        throw AdbProtocolException('Protobuf wire type $wire is not supported');
    }
    if (_offset > _bytes.length) throw const AdbProtocolException('A truncated protobuf field');
  }
}
