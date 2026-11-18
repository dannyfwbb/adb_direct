// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// External programs used as independent oracles. Tests that need one are skipped, with the reason, when it is not
/// installed.
abstract final class Tools {
  /// `openssl`, if on the PATH.
  static final String? openssl = _find(['openssl']);

  /// `adb`, from `ADB` or the PATH or the default Android SDK location.
  static final String? adb = _find([
    ?Platform.environment['ADB'],
    'adb',
    '${Platform.environment['HOME']}/Android/Sdk/platform-tools/adb',
  ]);

  /// Skip reason for tests needing [tool] named [name], or null to run.
  static String? skipUnless(String? tool, String name) => tool == null ? '$name is not installed' : null;

  /// Runs [executable] with [arguments] and returns its stdout as text. Throws with its output when it fails, and kills
  /// it after [timeout].
  static Future<String> run(
    String executable,
    List<String> arguments, {
    List<int>? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async => String.fromCharCodes(await runBytes(executable, arguments, stdin: stdin, timeout: timeout));

  /// Like [run] but returns raw stdout bytes.
  static Future<List<int>> runBytes(
    String executable,
    List<String> arguments, {
    List<int>? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final process = await Process.start(executable, arguments);
    if (stdin != null) process.stdin.add(stdin);
    await process.stdin.close();
    final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
    final err = process.stderr.fold<List<int>>([], (a, b) => a..addAll(b));
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw ProcessException(executable, arguments, 'timed out', -1);
      },
    );
    final stdout = await out;
    if (code != 0) {
      throw ProcessException(
        executable,
        arguments,
        '${String.fromCharCodes(await err)}${String.fromCharCodes(stdout)}',
        code,
      );
    }
    return stdout;
  }

  static String? _find(List<String> candidates) {
    for (final candidate in candidates) {
      try {
        final result = Process.runSync(candidate, ['version'], runInShell: false);
        if (result.exitCode == 0) return candidate;
      } on ProcessException {
        continue;
      }
    }
    return null;
  }
}
