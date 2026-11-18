// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../bytes.dart';
import '../clock.dart';
import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../stream/adb_stream.dart';
import '../stream/progress_watchdog.dart';
import 'incremental.dart';
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

  /// Whether this is an APEX module rather than an APK: its [name] ends with `.apex`, as `adb install` decides.
  bool get isApex => name.toLowerCase().endsWith('.apex');
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
/// Installs stream the APK straight to the package manager when the device can (`abb_exec` on Android 11+,
/// `cmd package` on Android 7+), and push it to a temporary file first on older devices, as `adb install` does.
/// Operations cannot be cancelled one by one; closing the connection ends them all.
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
  /// An APEX module ([AdbApk.isApex]) is staged: it takes effect after the next reboot. That needs the device's `apex`
  /// feature (Android 10+) and, on most builds, a debuggable device or a module signed with the platform's key.
  ///
  /// [onProgress] reports bytes the device has acknowledged. Throws [AdbInstallException] when the package manager
  /// refuses, with its code (`INSTALL_FAILED_VERSION_DOWNGRADE`, …) and exact answer, and [AdbNotSupportedException]
  /// for an APEX module on a device without APEX support.
  Future<void> install(
    AdbApk apk, {
    AdbInstallOptions options = const AdbInstallOptions(),
    AdbProgress? onProgress,
  }) async {
    final channel = _channel;
    if (apk.isApex) _checkApex(channel);
    final arguments = ['install', ...options.toArguments()];
    final output = channel == _Channel.pm
        ? await _withPushedFile(apk, onProgress, (path) => _run(channel, [...arguments, path]))
        : await _run(
            channel,
            [...arguments, '-S', '${apk.size}', if (apk.isApex) '--apex'],
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
    if (apks.any((apk) => apk.isApex)) {
      throw ArgumentError.value(apks, 'apks', 'contains an APEX module: install it alone or with installMultiPackage');
    }
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

  /// Installs several apps atomically: all or none (Android 10+). Each element of [packages] is one app's APKs, or a
  /// single APEX module.
  ///
  /// With an APEX module among them the whole set is staged (`--staged`) and takes effect after the next reboot, as
  /// `adb install-multi-package` does.
  Future<void> installMultiPackage(
    List<List<AdbApk>> packages, {
    AdbInstallOptions options = const AdbInstallOptions(),
    AdbProgress? onProgress,
  }) async {
    if (packages.isEmpty || packages.any((p) => p.isEmpty)) {
      throw ArgumentError.value(packages, 'packages', 'has an empty entry');
    }
    if (packages.any((apks) => apks.length > 1 && apks.any((apk) => apk.isApex))) {
      throw ArgumentError.value(packages, 'packages', 'has an APEX module together with other files in one entry');
    }
    final channel = _channel;
    if (channel == _Channel.pm) {
      throw const AdbNotSupportedException('Installing several apps atomically needs "cmd package" (Android 10+)');
    }
    final staged = packages.any((apks) => apks.first.isApex);
    if (staged) _checkApex(channel);
    final sizes = [for (final apks in packages) _total(apks)];
    final total = sizes.fold(0, (sum, size) => sum + size);
    final shared = [...options.toArguments(), if (staged) '--staged'];

    final parent = await _createSession(channel, ['--multi-package', ...shared]);
    final children = <int>[];
    try {
      var done = 0;
      for (final (i, apks) in packages.indexed) {
        final apex = apks.first.isApex;
        final child = await _createSession(channel, [...shared, '-S', '${sizes[i]}', if (apex) '--apex']);
        children.add(child);
        await _writeAll(channel, child, apks, done, total, onProgress);
        done += sizes[i];
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

  /// Installs one app (a base APK and its splits) incrementally, like `adb install --incremental` (Android 11+ with
  /// incremental delivery): the package manager answers once it has the blocks it needs to install, the app can start
  /// right away, and the rest of the blocks keep arriving in the background.
  ///
  /// Each file needs its v4 signature ([AdbIncrementalApk.signature]) to be served incrementally; files without one are
  /// sent whole first. Returns once the app is installed; keep the connection open until [AdbIncrementalInstall.done]
  /// completes, or the app stays incomplete on the device.
  ///
  /// Throws [AdbInstallException] when the package manager refuses (devices without incremental delivery fail here
  /// too), [AdbNotSupportedException] without `abb_exec` (Android 10 and older), [AdbTimeoutException] when it does
  /// not answer within `AdbConnectOptions.packageManagerTimeout`, and [ArgumentError] for a malformed signature or name.
  Future<AdbIncrementalInstall> installIncremental(
    List<AdbIncrementalApk> files, {
    AdbInstallOptions options = const AdbInstallOptions(),
  }) async {
    if (files.isEmpty) throw ArgumentError.value(files, 'files', 'is empty');
    final names = <String>{};
    for (final file in files) {
      if (file.name.isEmpty || file.name.contains(':') || !names.add(file.name)) {
        throw ArgumentError.value(file.name, 'files', 'names must be distinct, non-empty and without ":"');
      }
    }
    if (!_connection.supports(AdbFeature.abbExec)) {
      throw const AdbNotSupportedException('Incremental installs need abb_exec (Android 11 and later)');
    }
    final signed = <(AdbIncrementalApk, IdsigParts)>[];
    for (final file in files.where((f) => f.signature != null)) {
      try {
        signed.add((file, parseIdsig(file.signature!, file.size)));
      } on FormatException catch (e) {
        throw ArgumentError.value(file.name, 'files', 'has an invalid v4 signature: ${e.message}');
      }
    }
    final unsigned = files.where((f) => f.signature == null).toList();

    Future<void> release() async {
      for (final file in files) {
        try {
          await file.close?.call();
        } on Object {
          // Nothing more to do.
        }
      }
    }

    try {
      final stream = await _connection.open(
        _Channel.abbExec.service([
          'install-incremental',
          ...options.toArguments(),
          for (final (i, (file, parts)) in signed.indexed) incrementalArgument(file.name, file.size, i, parts.header),
          for (final (i, file) in unsigned.indexed) incrementalArgument(file.name, file.size, signed.length + i, null),
        ]),
      );
      // Files without a signature go through stdin, whole and in id order, before serving starts.
      for (final file in unsigned) {
        for (var offset = 0; offset < file.size; offset += _stdinPiece) {
          final piece = await file.read(offset, file.size - offset < _stdinPiece ? file.size - offset : _stdinPiece);
          if (piece.isEmpty) throw ArgumentError('${file.name} ended at $offset of ${file.size} bytes');
          await stream.write(piece);
        }
      }
      return await serveIncremental(stream, signed, release, clock: _connection.clock, answerTimeout: answerTimeout);
    } on Object {
      await release();
      rethrow;
    }
  }

  static const int _stdinPiece = 64 * 1024;

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

  /// The installed packages, as `pm list packages` gives them, with their base APK's path, installer, user ids
  /// (Android 8+) and version code (Android 9+).
  ///
  /// [system] true lists system packages only (`-s`), false the others (`-3`); [enabled] true lists enabled packages
  /// only (`-e`), false disabled ones (`-d`); [user] limits the list to one user. [apex] lists APEX modules instead of
  /// apps (Android 10+; they have no user ids).
  Future<List<AdbPackageInfo>> list({bool? system, bool? enabled, int? user, bool apex = false}) async {
    final sdk = await _connection.properties.sdkLevel() ?? 0;
    if (apex && sdk < 29) throw const AdbNotSupportedException('Listing APEX modules needs Android 10 or later');
    final output = await _pm([
      'list',
      'packages',
      '-f',
      '-i',
      if (sdk >= 26 && !apex) '-U',
      if (sdk >= 28) '--show-versioncode',
      if (apex) '--apex-only',
      if (system case final system?) system ? '-s' : '-3',
      if (enabled case final enabled?) enabled ? '-e' : '-d',
      if (user != null) ...['--user', '$user'],
    ], expectExitZero: true);
    return parsePackageList(output);
  }

  /// The paths of [package]'s APKs on the device: the base first, then its splits; empty when it is not installed (for
  /// [user]).
  Future<List<String>> paths(String package, {int? user}) async {
    final result = await _pmRaw([
      'path',
      if (user != null) ...['--user', '$user'],
      package,
    ]);
    return [
      for (final line in const LineSplitter().convert(result.$1))
        if (line.trim().startsWith('package:')) line.trim().substring('package:'.length),
    ];
  }

  /// Enables or disables [package] (or one component, `package/class`) for [user], like `pm enable` and
  /// `pm disable-user`. A disabled app stays installed and keeps its data, but cannot run and is hidden from the
  /// launcher.
  ///
  /// Throws [AdbCommandException] when the package manager refuses (an unknown package, a component the shell may not
  /// change).
  Future<void> setEnabled(String package, {required bool enabled, int? user}) => _pmExpect(
    [
      enabled ? 'enable' : 'disable-user',
      if (user != null) ...['--user', '$user'],
      package,
    ],
    'change the state of $package',
    (output) => output.contains('new state:'),
  );

  /// Deletes [package]'s data and caches for [user], like `pm clear`; the app stays installed.
  ///
  /// Throws [AdbCommandException] when the package manager refuses (`Failed` for an unknown package).
  Future<void> clearData(String package, {int? user}) => _pmExpect(
    [
      'clear',
      if (user != null) ...['--user', '$user'],
      package,
    ],
    'clear the data of $package',
    (output) => const LineSplitter().convert(output).any((line) => line.trim() == 'Success'),
  );

  /// Grants the runtime [permission] (`android.permission.CAMERA`, …) to [package], like `pm grant`. The app must ask
  /// for it in its manifest.
  ///
  /// Throws [AdbCommandException] when the package manager refuses. Some versions (Android 14) accept an unknown
  /// package without a word.
  Future<void> grantPermission(String package, String permission, {int? user}) =>
      _permission('grant', package, permission, user);

  /// Revokes the runtime [permission] from [package], like `pm revoke`.
  ///
  /// Throws [AdbCommandException] when the package manager refuses.
  Future<void> revokePermission(String package, String permission, {int? user}) =>
      _permission('revoke', package, permission, user);

  Future<void> _permission(String verb, String package, String permission, int? user) async {
    final (output, exitCode) = await _pmRaw([
      verb,
      if (user != null) ...['--user', '$user'],
      package,
      permission,
    ]);
    if ((exitCode ?? 0) != 0 || output.trim().isNotEmpty) {
      throw _commandFailure(output, '$verb $permission for $package', exitCode: exitCode);
    }
  }

  /// Runs `pm` with [arguments]; fails unless [succeeded] accepts its output.
  Future<void> _pmExpect(List<String> arguments, String what, bool Function(String output) succeeded) async {
    final (output, exitCode) = await _pmRaw(arguments);
    if (!succeeded(output)) throw _commandFailure(output, what, exitCode: exitCode);
  }

  /// Runs `pm` with [arguments] through the shell; returns stdout and stderr together. With [expectExitZero], a
  /// non-zero exit status fails.
  Future<String> _pm(List<String> arguments, {bool expectExitZero = false}) async {
    final (output, exitCode) = await _pmRaw(arguments);
    if (expectExitZero && (exitCode ?? 0) != 0) {
      throw _commandFailure(output, 'run pm ${arguments.first}', exitCode: exitCode);
    }
    return output;
  }

  Future<(String, int?)> _pmRaw(List<String> arguments) async {
    final result = await _connection.shell.run(_pmCommand(arguments), timeout: answerTimeout);
    return ('${result.stdoutText}${result.stderrText}'.replaceAll('\r\n', '\n'), result.exitCode);
  }

  static String _pmCommand(List<String> arguments) => 'pm ${arguments.map(shellQuote).join(' ')}';

  static AdbCommandException _commandFailure(String output, String what, {int? exitCode}) {
    final text = output.trim();
    // A Java stack trace says most in its second line (`java.lang.IllegalArgumentException: Unknown package: …`).
    final lines = const LineSplitter().convert(text).where((line) => line.trim().isNotEmpty).toList();
    final summary = lines.isEmpty
        ? 'no answer${exitCode == null ? '' : ' (exit status $exitCode)'}'
        : lines.first.startsWith('Exception occurred') && lines.length > 1
        ? lines[1].trim()
        : lines.first.trim();
    return AdbCommandException('Could not $what: $summary', command: 'pm', output: output, exitCode: exitCode);
  }

  void _checkApex(_Channel channel) {
    if (!_connection.supports(AdbFeature.apex) || channel == _Channel.pm) {
      throw const AdbNotSupportedException('This device cannot install APEX modules (needs the apex feature)');
    }
  }

  static int _total(List<AdbApk> apks) => apks.fold(0, (sum, apk) => sum + apk.size);

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
      final arguments = ['install-write', '-S', '${apk.size}', '$session', apk.name];
      final output = channel == _Channel.pm
          ? await _withPushedFile(apk, progress, (path) => _run(channel, [...arguments, path]))
          : await _run(channel, [...arguments, '-'], input: apk, onProgress: progress);
      _checkSuccess(output, 'write ${apk.name}');
      done += apk.size;
    }
  }

  Future<void> _commit(_Channel channel, int session) async {
    final output = await _run(channel, ['install-commit', '$session']);
    // Android 7's `cmd package install-commit` prints nothing when it succeeds (a failure still prints
    // `Failure [...]`). An empty answer from a connection that ended is no success.
    if (output.trim().isEmpty && channel == _Channel.cmd && !_connection.isClosed) return;
    _checkSuccess(output, 'commit');
  }

  /// Best effort: the session may be gone already.
  Future<void> _abandon(_Channel channel, int session) async {
    try {
      await _run(channel, ['install-abandon', '$session']);
    } on Object {
      // Nothing more to do.
    }
  }

  /// For old devices, which have no binary stdin through `shell:`: pushes [apk] to a temporary file, runs [use] with
  /// its path, and removes the file whatever happens, a failed push included.
  Future<T> _withPushedFile<T>(AdbApk apk, AdbProgress? onProgress, Future<T> Function(String path) use) async {
    final path = '/data/local/tmp/adb_direct_${randomHex()}.apk';
    try {
      await _connection.sync.write(path, apk.open(), size: apk.size, onProgress: onProgress);
      return await use(path);
    } finally {
      await _connection.shell.removeQuietly(path);
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
      await _connection.clock.deadline(finished.future, answerTimeout, () {
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
    final acknowledgements = stream.acknowledgements.listen((acked) => onProgress?.call(acked - start, apk.size));
    final copy = _ApkCopy(apk, stream);
    final watchdog = ProgressWatchdog(
      clock: _connection.clock,
      timeout: stallTimeout,
      // Movement of the source or of the device.
      progress: () => copy.sent + stream.acknowledgedBytes,
      onStall: () {
        unawaited(stream.close());
        copy.fail(AdbTimeoutException('The upload of ${apk.name} made no progress for $stallTimeout'));
      },
    );
    try {
      await copy.done;
      onProgress?.call(stream.acknowledgedBytes - start, apk.size);
    } finally {
      watchdog.stop();
      await acknowledgements.cancel();
    }
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
  if (const LineSplitter().convert(output).any((line) => line.trimLeft().startsWith('Success'))) return null;
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

/// One installed package, from `pm list packages`.
@immutable
final class AdbPackageInfo {
  /// Creates one.
  const AdbPackageInfo({required this.name, this.path, this.versionCode, this.installer, this.userIds = const []});

  /// The package name (`com.example.app`).
  final String name;

  /// The path of its base APK (or of the APEX file), when the device said.
  final String? path;

  /// Its version code (Android 9+).
  final int? versionCode;

  /// The package that installed it (`com.android.vending`), or null when none is recorded (system apps, `adb install`
  /// without `-i`).
  final String? installer;

  /// Its Linux user ids (Android 8+): one per Android user it is installed for (`10091` for user 0, `1010091` for
  /// user 10).
  final List<int> userIds;

  @override
  bool operator ==(Object other) =>
      other is AdbPackageInfo &&
      other.name == name &&
      other.path == path &&
      other.versionCode == versionCode &&
      other.installer == installer &&
      const ListEquality<int>().equals(other.userIds, userIds);

  @override
  int get hashCode => Object.hash(name, path, versionCode, installer, Object.hashAll(userIds));

  @override
  String toString() => 'AdbPackageInfo($name${versionCode == null ? '' : ' v$versionCode'})';
}

/// Parses `pm list packages -f -i [-U] [--show-versioncode]`: lines like
/// `package:/data/app/~~x==/com.example-y==/base.apk=com.example versionCode:3  installer=null uid:10091,1010091`.
/// The path itself may contain `=`; the package name never does. Other lines are ignored.
@internal
List<AdbPackageInfo> parsePackageList(String output) {
  final line = RegExp(
    r'^package:(?:(\S+)=)?([^=\s]+)(?:\s+versionCode:(\d+))?(?:\s+installer=(\S+))?(?:\s+uid:([\d,]+))?\s*$',
  );
  return [
    for (final text in const LineSplitter().convert(output))
      if (line.firstMatch(text.trim()) case final match?)
        AdbPackageInfo(
          name: match.group(2)!,
          path: match.group(1),
          versionCode: match.group(3) == null ? null : int.parse(match.group(3)!),
          installer: match.group(4) == null || match.group(4) == 'null' ? null : match.group(4),
          userIds: [
            for (final uid in (match.group(5) ?? '').split(','))
              if (uid.isNotEmpty) int.parse(uid),
          ],
        ),
  ];
}

/// Copies an APK into a stream, one chunk in flight at a time, and ends once the device has taken the last byte.
final class _ApkCopy {
  _ApkCopy(this._apk, this._stream) {
    _source = _apk.open().listen(_onChunk, onError: fail, onDone: _onDone, cancelOnError: true);
  }

  final AdbApk _apk;
  final AdbStream _stream;
  final Completer<void> _result = Completer<void>();
  late final StreamSubscription<List<int>> _source;

  /// Bytes taken from the source so far.
  int sent = 0;

  /// Completes when everything was sent and acknowledged; fails with the first error.
  Future<void> get done => _result.future;

  /// Ends the copy with [error] unless it ended already.
  void fail(Object error, [StackTrace? stackTrace]) {
    if (_result.isCompleted) return;
    _result.completeError(error, stackTrace);
    unawaited(_source.cancel());
  }

  void _onChunk(List<int> chunk) {
    sent += chunk.length;
    if (sent > _apk.size) {
      return fail(ArgumentError('${_apk.name} yielded more than the ${_apk.size} bytes announced'));
    }
    _source.pause();
    _stream.write(chunk).then((_) {
      if (!_result.isCompleted) _source.resume();
    }, onError: fail).ignore();
  }

  void _onDone() {
    if (_result.isCompleted) return;
    if (sent != _apk.size) {
      return fail(ArgumentError('${_apk.name} yielded $sent bytes, not the ${_apk.size} announced'));
    }
    // The device has to take the last bytes before the silent verification phase starts.
    _stream.flush().then((_) {
      if (!_result.isCompleted) _result.complete();
    }, onError: fail).ignore();
  }
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
