// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import 'shell.dart';

/// System properties of the device (`getprop`, `setprop`): [AdbConnection.properties].
///
/// Each call runs `getprop` or `setprop` through the shell; nothing is cached except [sdkLevel], which cannot change
/// while a connection is up.
final class AdbProperties {
  /// Creates the namespace for [_connection].
  @internal
  AdbProperties(this._connection);

  final AdbConnection _connection;

  int? _sdkLevel;
  bool _sdkKnown = false;

  /// The value of the property [name], or null when it is not set (`getprop` prints an empty line for both an unset
  /// and an empty property, so an empty value is null too).
  Future<String?> get(String name) async {
    _checkName(name);
    final result = await _connection.shell.run('getprop ${shellQuote(name)}');
    _checkExit(result, 'getprop $name');
    final value = _trimLineEnd(result.stdoutText);
    return value.isEmpty ? null : value;
  }

  /// Every property the shell user can read, by name.
  Future<Map<String, String>> all() async {
    final result = await _connection.shell.run('getprop');
    _checkExit(result, 'getprop');
    return parseGetprop(result.stdoutText);
  }

  /// Sets the property [name] to [value] (`setprop`). Most properties are writable only by the system; the shell user
  /// may set `debug.*`, `log.tag.*`, `persist.log.tag.*` and a few more.
  ///
  /// Throws [AdbCommandException] when the device refuses. Old devices (before Android 9) refuse silently: read the
  /// property back to be sure.
  Future<void> set(String name, String value) async {
    _checkName(name);
    if (value.contains('\n') || value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'contains a line break or NUL');
    }
    final command = 'setprop ${shellQuote(name)} ${shellQuote(value)}';
    final result = await _connection.shell.run(command);
    final output = '${result.stdoutText}${result.stderrText}'.trim();
    if ((result.exitCode ?? 0) != 0 || output.isNotEmpty) {
      throw AdbCommandException(
        'Could not set $name: ${output.isEmpty ? 'exit status ${result.exitCode}' : output}',
        command: command,
        output: output,
        exitCode: result.exitCode,
      );
    }
  }

  /// The device's serial number (`ro.serialno`, else `ro.boot.serialno`), as `adb get-serialno` shows it for a USB
  /// device; null when the device has none (some emulators and TVs).
  ///
  /// Over the network, `adb devices` names a device by its address instead.
  Future<String?> serialNumber() async => await get('ro.serialno') ?? await get('ro.boot.serialno');

  /// The device's API level (`ro.build.version.sdk`, 19 for Android 4.4, 34 for Android 14), or null when the
  /// property is missing or not a number. Asked once per connection.
  Future<int?> sdkLevel() async {
    if (_sdkKnown) return _sdkLevel;
    final text = await get('ro.build.version.sdk');
    _sdkLevel = text == null ? null : int.tryParse(text.trim());
    _sdkKnown = true;
    return _sdkLevel;
  }

  static void _checkName(String name) {
    if (name.isEmpty || name.contains(RegExp(r'[\s\u0000]'))) {
      throw ArgumentError.value(name, 'name', 'is empty or contains white space');
    }
  }

  static void _checkExit(AdbShellResult result, String command) {
    if ((result.exitCode ?? 0) == 0) return;
    final output = '${result.stdoutText}${result.stderrText}';
    throw AdbCommandException(
      '"$command" failed with exit status ${result.exitCode}: ${output.trim()}',
      command: command,
      output: output,
      exitCode: result.exitCode,
    );
  }

  /// [text] without its last line end (LF, or CR LF from a PTY).
  static String _trimLineEnd(String text) {
    if (text.endsWith('\r\n')) return text.substring(0, text.length - 2);
    if (text.endsWith('\n')) return text.substring(0, text.length - 1);
    return text;
  }
}

/// Parses what `getprop` prints: `[name]: [value]` lines, where a value may run over several lines.
///
/// Line ends may be LF or CR LF (old devices print through a PTY). Lines that start no entry and continue none are
/// ignored.
@internal
Map<String, String> parseGetprop(String text) {
  final properties = <String, String>{};
  final start = RegExp(r'^\[([^\]]+)\]: \[(.*)$');
  String? name;
  StringBuffer? value;

  for (final rawLine in text.split('\n')) {
    final line = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
    if (name == null || value == null) {
      final match = start.firstMatch(line);
      if (match == null) continue;
      name = match.group(1);
      value = StringBuffer();
      final rest = match.group(2)!;
      if (rest.endsWith(']')) {
        properties[name!] = rest.substring(0, rest.length - 1);
        name = null;
        value = null;
      } else {
        value.write(rest);
      }
      continue;
    }
    // Inside a value that spans lines.
    value.write('\n');
    if (line.endsWith(']')) {
      value.write(line.substring(0, line.length - 1));
      properties[name] = value.toString();
      name = null;
      value = null;
    } else {
      value.write(line);
    }
  }
  return properties;
}
