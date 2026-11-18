// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../stream/adb_stream.dart';
import '../stream/progress_watchdog.dart';
import 'shell.dart';
import 'sync.dart';

/// One APK to install: its size and a way to read it.
@immutable
final class AdbApk {
  /// An APK read from [open], which must yield exactly [size] bytes each time it is called. [name] names it on the
  /// device (split APKs need distinct names; a file name is a good choice).
  const AdbApk({required this.name, required this.size, required this.open});

  /// An APK file on `dart:io`.
  factory AdbApk.file(File file) =>
      AdbApk(name: file.uri.pathSegments.last, size: file.lengthSync(), open: file.openRead);

  /// An APK in memory.
  factory AdbApk.bytes(String name, List<int> bytes) =>
      AdbApk(name: name, size: bytes.length, open: () => Stream.value(bytes));

  /// The name on the device.
  final String name;

  /// Size in bytes.
  final int size;

  /// Opens the content.
  final Stream<List<int>> Function() open;
}

/// Options of `pm install`.
@immutable
final class AdbInstallOptions {
  /// Creates options; by default an existing app is replaced and nothing else is changed.
  const AdbInstallOptions({
    this.allowDowngrade = false,
    this.grantPermissions = false,
    this.allowTest = false,
    this.user,
    this.installerPackage,
    this.instant = false,
    this.abi,
    this.bypassLowTargetSdkBlock = false,
    this.extraArguments = const [],
  });

  /// `-d`: allow a lower version code than the installed one. Android 12+ allows it only for debuggable apps (or on
  /// debuggable builds).
  final bool allowDowngrade;

  /// `-g`: grant every runtime permission the app asks for.
  final bool grantPermissions;

  /// `-t`: allow test packages (`android:testOnly`).
  final bool allowTest;

  /// `--user`: install for this user only.
  final int? user;

  /// `-i`: the installer package name to record.
  final String? installerPackage;

  /// `--instant`: install as an instant app.
  final bool instant;

  /// `--abi`: force this ABI.
  final String? abi;

  /// `--bypass-low-target-sdk-block`: Android 14 and later refuse apps that target a very old SDK without it.
  final bool bypassLowTargetSdkBlock;

  /// More arguments, passed as they are.
  final List<String> extraArguments;

  /// The arguments, in `pm`'s syntax. `-r` (replace) is always included: current `pm` ignores it, old ones need it.
  List<String> toArguments() => [
    '-r',
    if (allowDowngrade) '-d',
    if (grantPermissions) '-g',
    if (allowTest) '-t',
    if (user case final user?) ...['--user', '$user'],
    if (installerPackage case final installer?) ...['-i', installer],
    if (instant) '--instant',
    if (abi case final abi?) ...['--abi', abi],
    if (bypassLowTargetSdkBlock) '--bypass-low-target-sdk-block',
    ...extraArguments,
  ];
}

/// Apps on the device: [AdbConnection.packages].
///
/// Installs stream the APK straight to the package manager when the device can (`abb_exec` on Android 11+, `cmd
/// package` on Android 7+), and push it to a temporary file first on older devices, as `adb install` does. Operations
/// cannot be cancelled one by one; closing the connection ends them all.
final class AdbPackages {
  /// Creates the namespace for [_connection].
  @internal
  AdbPackages(this._connection, {required this.stallTimeout, required this.answerTimeout});

  final AdbConnection _connection;

  /// How long an upload may make no progress (nothing acknowledged, or the source yields nothing).
  final Duration stallTimeout;

  /// How long the package manager may take to answer a command; after an upload it verifies and optimizes the app in
  /// silence (slow TVs take minutes).
  final Duration answerTimeout;

  _Channel get _channel {
    if (_connection.supports(AdbFeature.abbExec)) return _Channel.abbExec;
    if (_connection.supports(AdbFeature.cmd)) return _Channel.cmd;
    return _Channel.pm;
  }

  /// Installs [apk], replacing an installed version.
  ///
  /// [onProgress] reports bytes the device has acknowledged. Throws [AdbInstallException] when the package manager
  /// refuses, with its code (`INSTALL_FAILED_VERSION_DOWNGRADE`, …) and exact answer.
  Future<void> install(
    AdbApk apk, {
    AdbInstallOptions options = const AdbInstallOptions(),
    AdbProgress? onProgress,
  }) async {
    final channel = _channel;
    if (channel == _Channel.pm) {
      return _withPushedFile(apk, onProgress, (path) async {
        _checkSuccess(await _run(channel, ['install', ...options.toArguments(), path]), 'install ${apk.name}');
      });
    }
    final output = await _run(
      channel,
      ['install', ...options.toArguments(), '-S', '${apk.size}'],
      input: apk,
      onProgress: onProgress,
    );
    _checkSuccess(output, 'install ${apk.name}');
  }

  /// Installs one app made of several APKs (a base and its splits), in one package manager session that is committed
  /// only when every APK arrived. Any failure abandons the session.
  Future<void> installMultiple(
    List<AdbApk> apks, {
    AdbInstallOptions options = const AdbInstallOptions(),
    AdbProgress? onProgress,
  }) async {
    if (apks.isEmpty) throw ArgumentError.value(apks, 'apks', 'is empty');
    final channel = _channel;
    final total = _total(apks);
    final session = await _createSession(channel, [...options.toArguments(), '-S', '$total']);
    try {
      await _writeAll(channel, session, apks, 0, total, onProgress);
      await _commit(channel, session);
    } on Object {
      await _abandon(channel, session);
      rethrow;
    }
  }

  /// Installs several apps atomically: all or none (Android 10+). Each element of [packages] is one app's APKs.
  Future<void> installMultiPackage(
    List<List<AdbApk>> packages, {
    AdbInstallOptions options = const AdbInstallOptions(),
    AdbProgress? onProgress,
  }) async {
    if (packages.isEmpty || packages.any((p) => p.isEmpty)) {
      throw ArgumentError.value(packages, 'packages', 'has an empty entry');
    }
    final channel = _channel;
    if (channel == _Channel.pm) {
      throw const AdbNotSupportedException('Installing several apps atomically needs "cmd package" (Android 10+)');
    }
    final total = packages.fold<int>(0, (sum, p) => sum + _total(p));
    final parent = await _createSession(channel, ['--multi-package', ...options.toArguments()]);
    final children = <int>[];
    try {
      var done = 0;
      for (final apks in packages) {
        final child = await _createSession(channel, [...options.toArguments(), '-S', '${_total(apks)}']);
        children.add(child);
        await _writeAll(channel, child, apks, done, total, onProgress);
        done += _total(apks);
      }
      _checkSuccess(
        await _run(channel, ['install-add-session', '$parent', ...children.map((c) => '$c')]),
        'add the sessions',
      );
      await _commit(channel, parent);
    } on Object {
      for (final session in [...children, parent]) {
        await _abandon(channel, session);
      }
      rethrow;
    }
  }

  /// Removes [package]. With [keepData] its data and caches stay (`-k`).
  ///
  /// Throws [AdbInstallException] when the package manager refuses: `DELETE_FAILED_INTERNAL_ERROR` for an app that is
  /// not installed, or no code (`Failure [not installed for 0]`) when it is missing only for that [user].
  Future<void> uninstall(String package, {bool keepData = false, int? user}) async {
    final output = await _run(_channel, [
      'uninstall',
      if (keepData) '-k',
      if (user != null) ...['--user', '$user'],
      package,
    ]);
    _checkSuccess(output, 'uninstall $package');
  }

  static int _total(List<AdbApk> apks) => apks.fold<int>(0, (sum, apk) => sum + apk.size);

  Future<int> _createSession(_Channel channel, List<String> arguments) async {
    final output = await _run(channel, ['install-create', ...arguments]);
    if (pmSessionId(output) case final id?) return id;
    if (output.toLowerCase().contains('unknown command')) {
      throw const AdbNotSupportedException('This device has no install sessions (Android 5 and later)');
    }
    throw _failure(output, 'create an install session');
  }

  Future<void> _writeAll(
    _Channel channel,
    int session,
    List<AdbApk> apks,
    int before,
    int total,
    AdbProgress? onProgress,
  ) async {
    var done = before;
    for (final apk in apks) {
      final base = done;
      void progress(int sent, int? _) => onProgress?.call(base + sent, total);
      if (channel == _Channel.pm) {
        // Old devices: no binary stdin through "shell:", so push the APK and give pm its path.
        await _withPushedFile(apk, progress, (path) async {
          _checkSuccess(
            await _run(channel, ['install-write', '-S', '${apk.size}', '$session', apk.name, path]),
            'write ${apk.name}',
          );
        });
      } else {
        _checkSuccess(
          await _run(
            channel,
            ['install-write', '-S', '${apk.size}', '$session', apk.name, '-'],
            input: apk,
            onProgress: progress,
          ),
          'write ${apk.name}',
        );
      }
      done += apk.size;
    }
  }

  Future<void> _commit(_Channel channel, int session) async {
    final output = await _run(channel, ['install-commit', '$session']);
    // Android 7's `cmd package install-commit` prints nothing when it succeeds (a failure still prints `Failure
    // [...]`). An empty answer from a connection that ended is no success.
    if (output.trim().isEmpty && channel == _Channel.cmd && !_connection.isClosed) {
      return;
    }
    _checkSuccess(output, 'commit');
  }

  Future<void> _abandon(_Channel channel, int session) =>
      _run(channel, ['install-abandon', '$session']).then<void>((_) {}, onError: (Object _) {});

  /// Pushes [apk] to a temporary file, runs [use] with its path, and removes the file whatever happens, a failed push
  /// included.
  Future<void> _withPushedFile(AdbApk apk, AdbProgress? onProgress, Future<void> Function(String path) use) async {
    final id = Random.secure().nextInt(1 << 32).toRadixString(16);
    final path = '/data/local/tmp/adb_direct_$id.apk';
    try {
      await _connection.sync.write(path, apk.open(), size: apk.size, onProgress: onProgress);
      await use(path);
    } finally {
      await _connection.shell.run('rm -f ${shellQuote(path)}').then<void>((_) {}, onError: (Object _) {});
    }
  }

  /// Runs a package manager command; streams [input] to its stdin; returns what it printed.
  Future<String> _run(_Channel channel, List<String> arguments, {AdbApk? input, AdbProgress? onProgress}) async {
    final stream = await _connection.open(channel.service(arguments));
    final output = BytesBuilder(copy: false);
    final finished = Completer<void>();
    // Awaited only after the upload: a failure meanwhile must not surface as an unhandled error.
    finished.future.ignore();
    final subscription = stream.input.listen(
      (data) {
        if (output.length < _maxOutput) output.add(data);
      },
      onError: (Object e) {
        if (!finished.isCompleted) finished.completeError(e);
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
    );
    try {
      if (input != null) await _upload(stream, input, onProgress);
      await _deadline(finished.future, answerTimeout, () {
        unawaited(stream.close());
        return AdbTimeoutException('The package manager did not answer "${arguments.first}" within $answerTimeout');
      });
    } finally {
      await subscription.cancel();
    }
    return utf8.decode(output.takeBytes(), allowMalformed: true);
  }

  static const int _maxOutput = 1024 * 1024;

  /// Streams [apk] into [stream] and waits until the device has acknowledged all of it. Fails with
  /// [AdbTimeoutException] when neither the source nor the device moves for [stallTimeout].
  Future<void> _upload(AdbStream stream, AdbApk apk, AdbProgress? onProgress) async {
    final start = stream.acknowledgedBytes;
    final result = Completer<void>();
    var sent = 0;
    late final StreamSubscription<List<int>> source;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (result.isCompleted) return;
      result.completeError(error, stackTrace);
      unawaited(source.cancel());
    }

    final acknowledgements = stream.acknowledgements.listen((acknowledged) {
      onProgress?.call(acknowledged - start, apk.size);
    });
    final watchdog = ProgressWatchdog(
      clock: _connection.clock,
      timeout: stallTimeout,
      // Movement of the source or of the device.
      progress: () => sent + stream.acknowledgedBytes,
      onStall: () {
        unawaited(stream.close());
        fail(AdbTimeoutException('The upload of ${apk.name} made no progress for $stallTimeout'));
      },
    );

    source = apk.open().listen(
      (chunk) {
        sent += chunk.length;
        if (sent > apk.size) {
          fail(ArgumentError('${apk.name} yielded more than the ${apk.size} bytes announced'));
          return;
        }
        source.pause();
        unawaited(
          stream.write(chunk).then((_) {
            if (!result.isCompleted) source.resume();
          }, onError: fail),
        );
      },
      onError: fail,
      onDone: () {
        if (result.isCompleted) return;
        if (sent != apk.size) {
          fail(ArgumentError('${apk.name} yielded $sent bytes, not the ${apk.size} announced'));
          return;
        }
        // The device has to take the last bytes before the silent verification phase starts.
        unawaited(
          stream.flush().then((_) {
            if (!result.isCompleted) result.complete();
          }, onError: fail),
        );
      },
      cancelOnError: true,
    );
    try {
      await result.future;
      onProgress?.call(stream.acknowledgedBytes - start, apk.size);
    } finally {
      watchdog.stop();
      await acknowledgements.cancel();
    }
  }

  Future<void> _deadline(Future<void> future, Duration timeout, AdbException Function() onTimeout) {
    final completer = Completer<void>();
    final Timer timer = _connection.clock.timer(timeout, () {
      if (!completer.isCompleted) completer.completeError(onTimeout());
    });
    unawaited(
      future.then(
        (_) {
          timer.cancel();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (Object e, StackTrace s) {
          timer.cancel();
          if (!completer.isCompleted) completer.completeError(e, s);
        },
      ),
    );
    return completer.future;
  }

  static void _checkSuccess(String output, String what) {
    if (pmFailure(output, what) case final failure?) throw failure;
  }

  static AdbInstallException _failure(String output, String what) =>
      pmFailure(output, what) ?? AdbInstallException('Could not $what: $output', output: output);
}

/// The failure in a package manager answer, or null when a line starts with `Success`. `Failure [CODE: message]` and
/// `Failure [CODE]` give the code; anything else (a stack trace) keeps only the text. The exit status is never trusted:
/// `pm` often exits 0 after refusing.
@internal
AdbInstallException? pmFailure(String output, String what) {
  for (final line in const LineSplitter().convert(output)) {
    if (line.trimLeft().startsWith('Success')) return null;
  }
  final match = RegExp(r'Failure \[([A-Z0-9_]+)(?::[^\]]*)?\]').firstMatch(output);
  final text = output.trim();
  return AdbInstallException(
    'Could not $what: ${text.isEmpty ? 'no answer' : text}',
    failureCode: match?.group(1),
    output: output,
  );
}

/// The session id in an `install-create` answer (`Success: created install session [1234567]`), possibly after other
/// lines, or null.
@internal
int? pmSessionId(String output) {
  final match = RegExp(r'^\s*Success.*\[(\d+)\]', multiLine: true).firstMatch(output);
  return match == null ? null : int.parse(match.group(1)!);
}

/// How package manager commands reach the device.
enum _Channel {
  /// `abb_exec:package\0…`: Binder, no shell (Android 11+).
  abbExec,

  /// `exec:cmd package …` (Android 7+).
  cmd,

  /// `shell:pm …` (older; no binary stdin).
  pm;

  String service(List<String> arguments) => switch (this) {
    abbExec => 'abb_exec:${['package', ...arguments].join('\u0000')}',
    cmd => 'exec:cmd package ${arguments.map(shellQuote).join(' ')}',
    pm => 'shell:pm ${arguments.map(shellQuote).join(' ')}',
  };
}
