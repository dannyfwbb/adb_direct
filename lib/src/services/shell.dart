// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../bytes.dart';
import '../clock.dart';
import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/shell_protocol.dart';
import '../stream/adb_stream.dart';

/// Quotes [argument] for the device's shell: one argument, whatever it contains.
String shellQuote(String argument) {
  if (argument.isNotEmpty && RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(argument)) return argument;
  return "'${argument.replaceAll("'", r"'\''")}'";
}

/// The outcome of [AdbShell.run].
@immutable
final class AdbShellResult {
  /// Creates a result.
  const AdbShellResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.separateStreams,
    required this.truncated,
  });

  /// What the command wrote to stdout (with stderr mixed in when [separateStreams] is false).
  final Uint8List stdout;

  /// What the command wrote to stderr; always empty when [separateStreams] is false.
  final Uint8List stderr;

  /// The exit status, or null when it could not be learned (an old device whose shell did not run our status echo, for
  /// example after `exit`).
  final int? exitCode;

  /// Whether stdout and stderr came separately (shell protocol v2, Android 7+). Older devices merge them.
  final bool separateStreams;

  /// Whether output went past the limit and the command was cut off.
  final bool truncated;

  /// [stdout] as UTF-8 text (malformed bytes replaced).
  String get stdoutText => utf8.decode(stdout, allowMalformed: true);

  /// [stderr] as UTF-8 text (malformed bytes replaced).
  String get stderrText => utf8.decode(stderr, allowMalformed: true);

  @override
  String toString() =>
      'AdbShellResult(exit $exitCode, ${stdout.length} B out, ${stderr.length} B err${truncated ? ', truncated' : ''})';
}

/// Shell commands on a device: [AdbConnection.shell].
final class AdbShell {
  /// Creates the namespace for [_connection].
  @internal
  AdbShell(this._connection);

  final AdbConnection _connection;

  /// Whether the device speaks shell protocol v2 (separate stdout and stderr, exit status).
  bool get supportsShellProtocol => _connection.supports(AdbFeature.shellV2);

  /// Runs [command] with `sh -c` on the device and collects its output.
  ///
  /// The command gets an empty stdin. Output past [maxOutputBytes] (stdout and stderr together) stops the command and
  /// sets [AdbShellResult.truncated]. A command still running after [timeout] is stopped and the call throws
  /// [AdbTimeoutException]; the connection stays usable.
  Future<AdbShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    int maxOutputBytes = 16 * 1024 * 1024,
  }) {
    final v2 = supportsShellProtocol;
    final marker = v2 ? null : _exitMarker();
    AdbStream? stream;
    var timedOut = false;

    Future<AdbShellResult> collect() async {
      var pty = false;
      if (v2) {
        stream = _connection.openStream('shell,v2,raw:$command');
      } else {
        // Old devices: no exit status in the protocol; ask the shell to print it after the command, behind a marker no
        // output contains. stdin cannot be closed there, so it is empty from the start, as with the protocol; a
        // subshell keeps an `exit` from skipping the marker.
        (stream, pty) = await openRaw('exec </dev/null\n(\n$command\n)\necho $marker\$?');
      }
      final open = stream!;
      if (timedOut) {
        await open.close();
        throw AdbTimeoutException('"$command" timed out while opening');
      }

      final collector = _Collector(maxOutputBytes, v2: v2, pty: pty);
      if (v2) {
        // An empty stdin: commands that read it end at once.
        unawaited(open.write(ShellProtocol.encode(ShellPacketId.closeStdin, const [])).catchError((Object _) {}));
      }
      // Leaving the loop (output past the limit, a broken packet) cancels the input, which closes the stream.
      await for (final data in open.input) {
        if (collector.add(data)) break;
      }
      return collector.result(marker);
    }

    // The deadline covers everything, the open included.
    return _connection.clock.deadline(collect(), timeout, () {
      timedOut = true;
      unawaited(stream?.close());
      return AdbTimeoutException('"$command" did not finish within $timeout');
    });
  }

  /// Whether `exec:` exists (Android 5 and later); null until tried.
  bool? _execWorks;

  /// A stream for [script] without shell protocol v2: `exec:` (no PTY, stdout and stderr together) where it exists
  /// (Android 5+), else `shell:`, whose PTY turns line ends into CR LF. Returns whether it is the PTY.
  @internal
  Future<(AdbStream, bool)> openRaw(String script) async {
    if (_execWorks != false) {
      try {
        final stream = await _connection.open('exec:$script');
        _execWorks = true;
        return (stream, false);
      } on AdbServiceUnavailableException {
        if (_execWorks == true) rethrow;
        _execWorks = false;
      }
    }
    return (await _connection.open('shell:$script'), true);
  }

  /// Removes [path] on the device, ignoring any failure: for temporary files, whatever else went wrong.
  @internal
  Future<void> removeQuietly(String path) async {
    try {
      await run('rm -f ${shellQuote(path)}');
    } on Object {
      // Best effort.
    }
  }

  /// Opens `exec:` for [command]: raw bytes both ways, no PTY, no protocol. Use it for binary output such as
  /// `screencap -p`, or to feed a command through stdin (close the stream to end it).
  Future<AdbStream> exec(String command) => _connection.open('exec:$command');

  /// Starts an interactive session: [command] (a login shell when empty) with a PTY when [pty] is true, the terminal
  /// type [terminal].
  ///
  /// On devices without shell protocol v2 (Android 6 and older) the session always has a PTY and no separate stderr,
  /// exit status or window size; asking for `pty: false` there throws [AdbNotSupportedException].
  Future<AdbShellSession> start({String command = '', bool pty = true, String terminal = 'xterm-256color'}) async {
    final v2 = supportsShellProtocol;
    if (!v2 && !pty) {
      throw const AdbNotSupportedException(
        'This device has no shell protocol v2: a session without a PTY is not possible; use exec instead',
      );
    }
    final service = v2
        ? 'shell,v2,TERM=$terminal,${pty ? 'pty' : 'raw'}:$command'
        // Before Android 7 adbd knows only "shell:" (always with a PTY).
        : 'shell:$command';
    final stream = await _connection.open(service);
    return AdbShellSession._(stream, shellProtocol: v2);
  }

  static String _exitMarker() {
    return 'ADB_DIRECT_EXIT_${randomHex(6)}_';
  }
}

/// Gathers a command's output up to a limit.
final class _Collector {
  _Collector(this._limit, {required this.v2, required this.pty});

  final int _limit;
  final bool v2;

  /// Output came through a PTY: its CR LF line ends become LF.
  final bool pty;
  final ShellPacketReader _packets = ShellPacketReader();
  final BytesBuilder _stdout = BytesBuilder(copy: false);
  final BytesBuilder _stderr = BytesBuilder(copy: false);
  int? _exitCode;
  bool _truncated = false;

  /// Adds stream data; returns true when the limit was reached.
  bool add(Uint8List data) {
    if (_truncated) return true;
    if (!v2) return _keep(_stdout, data);
    _packets.add(data);
    for (final packet in _packets.drain()) {
      switch (packet.id) {
        case ShellPacketId.stdout:
          if (_keep(_stdout, packet.data)) return true;
        case ShellPacketId.stderr:
          if (_keep(_stderr, packet.data)) return true;
        case ShellPacketId.exit:
          if (packet.data.isNotEmpty) _exitCode = packet.data.first;
        case ShellPacketId.stdin || ShellPacketId.closeStdin || ShellPacketId.windowSizeChange || null:
          break; // Host-to-device ids, or unknown ones: nothing for us.
      }
    }
    return false;
  }

  bool _keep(BytesBuilder into, Uint8List data) {
    final room = _limit - _stdout.length - _stderr.length;
    if (data.length <= room) {
      into.add(data);
      return false;
    }
    into.add(Uint8List.sublistView(data, 0, room < 0 ? 0 : room));
    _truncated = true;
    return true;
  }

  AdbShellResult result(String? marker) {
    var stdout = _stdout.takeBytes();
    var exitCode = _exitCode;
    if (marker != null && !_truncated) {
      (stdout, exitCode) = _stripExitMarker(stdout, marker);
    }
    if (pty) stdout = _fromCrLf(stdout);
    return AdbShellResult(
      stdout: stdout,
      stderr: _stderr.takeBytes(),
      exitCode: exitCode,
      separateStreams: v2,
      truncated: _truncated,
    );
  }

  static Uint8List _fromCrLf(Uint8List bytes) {
    final out = BytesBuilder(copy: false);
    var start = 0;
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10) {
        out.add(Uint8List.sublistView(bytes, start, i));
        start = i + 1;
      }
    }
    out.add(Uint8List.sublistView(bytes, start));
    return out.takeBytes();
  }

  /// Removes `<marker><status>\n` (or `\r\n`) from the end of [output].
  static (Uint8List, int?) _stripExitMarker(Uint8List output, String marker) {
    // The marker, up to three digits and a line end: only the tail matters.
    final tailStart = max(0, output.length - marker.length - 8);
    final tail = latin1.decode(Uint8List.sublistView(output, tailStart));
    final match = RegExp('${RegExp.escape(marker)}(\\d{1,3})\\r?\\n?\$').firstMatch(tail);
    if (match == null) return (output, null);
    return (Uint8List.sublistView(output, 0, tailStart + match.start), int.parse(match[1]!));
  }
}

/// An interactive shell: [AdbShell.start].
final class AdbShellSession {
  AdbShellSession._(this._stream, {required this.shellProtocol}) {
    _subscription = _stream.input.listen(
      _onData,
      onError: (Object error) {
        _stdout.addError(error);
        _finish(null);
      },
      onDone: () => _finish(_exit),
    );
    // Nothing is read from the device until someone listens to stdout.
    _syncPause();
  }

  final AdbStream _stream;
  late final StreamController<Uint8List> _stdout = _output();
  late final StreamController<Uint8List> _stderr = _output();
  late final StreamSubscription<Uint8List> _subscription;
  final ShellPacketReader _packets = ShellPacketReader();
  final Completer<int?> _exitCode = Completer<int?>();
  int? _exit;
  bool _finished = false;

  /// Whether the session uses shell protocol v2 (separate stderr, exit status, window size).
  final bool shellProtocol;

  /// The command's output (the terminal's, with a PTY).
  Stream<Uint8List> get stdout => _stdout.stream;

  /// The command's stderr; empty with a PTY or without shell protocol v2.
  Stream<Uint8List> get stderr => _stderr.stream;

  /// The exit status when the session ends, or null when it is unknown (no shell protocol v2) or the session failed:
  /// see [closeReason].
  Future<int?> get exitCode => _exitCode.future;

  /// Why the session ended abnormally (the connection failed), or null.
  AdbException? get closeReason => _stream.closeReason;

  /// Sends [data] to the command's stdin.
  Future<void> write(List<int> data) =>
      _stream.write(shellProtocol ? ShellProtocol.encode(ShellPacketId.stdin, data) : data);

  /// Ends stdin (EOF for a command without a PTY). Without shell protocol v2 the only way to end stdin is [close].
  Future<void> closeStdin() async {
    if (!shellProtocol) return;
    await _stream.write(ShellProtocol.encode(ShellPacketId.closeStdin, const []));
  }

  /// Tells the PTY its size. Ignored without shell protocol v2.
  Future<void> resize({required int rows, required int columns, int widthPixels = 0, int heightPixels = 0}) async {
    if (!shellProtocol) return;
    await _stream.write(
      ShellProtocol.encode(
        ShellPacketId.windowSizeChange,
        ascii.encode('${rows}x$columns,${widthPixels}x$heightPixels'),
      ),
    );
  }

  /// Ends the session.
  Future<void> close() => _stream.close();

  StreamController<Uint8List> _output() => StreamController<Uint8List>(
    onListen: _syncPause,
    onPause: _syncPause,
    onResume: _syncPause,
    onCancel: _syncPause,
  );

  void _onData(Uint8List data) {
    if (!shellProtocol) {
      _stdout.add(data);
      return;
    }
    _packets.add(data);
    try {
      _deliver();
    } on AdbProtocolException catch (e) {
      _stdout.addError(e);
      unawaited(_stream.close());
    }
  }

  void _deliver() {
    for (final packet in _packets.drain()) {
      switch (packet.id) {
        case ShellPacketId.stdout:
          _stdout.add(packet.data);
        case ShellPacketId.stderr:
          _stderr.add(packet.data);
        case ShellPacketId.exit:
          if (packet.data.isNotEmpty) _exit = packet.data.first;
        case ShellPacketId.stdin || ShellPacketId.closeStdin || ShellPacketId.windowSizeChange || null:
          break; // Host-to-device ids, or unknown ones: nothing for us.
      }
    }
  }

  /// Holds the device back while nobody listens to stdout, or a listener of either output is paused. (Unread stderr is
  /// kept: it is small.)
  void _syncPause() {
    final paused = !_stdout.hasListener || _stdout.isPaused || (_stderr.hasListener && _stderr.isPaused);
    if (paused && !_subscription.isPaused) {
      _subscription.pause();
    } else if (!paused && _subscription.isPaused) {
      _subscription.resume();
    }
  }

  /// Ends the outputs, then reports the exit status once every listener has received all output, so awaiting [exitCode]
  /// never races the last bytes.
  void _finish(int? exit) {
    if (_finished) return;
    _finished = true;
    unawaited(Future.wait([_close(_stdout), _close(_stderr)]).then((_) => _exitCode.complete(exit)));
  }

  /// Closes [output]; completes when its listener has had everything, or at once when nobody listens (the done event
  /// would wait for a listener forever).
  static Future<void> _close(StreamController<Uint8List> output) {
    final heard = output.hasListener;
    final closed = output.close();
    return heard ? closed : Future.value();
  }
}
