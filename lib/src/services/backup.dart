// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import 'shell.dart';

/// `adb backup` and `adb restore` (the `bu` tool). Deprecated on the device side since Android 12 and limited to apps
/// that allow it, but still there. The device asks its user to confirm on screen.
final class AdbBackup {
  /// Creates the namespace.
  @internal
  AdbBackup(this._connection);

  final AdbConnection _connection;

  /// The backup archive for [arguments] (`-apk`, `-shared`, `-all`, package names, … as for `adb backup`), streamed as
  /// the device produces it after the user confirms.
  Stream<Uint8List> create(List<String> arguments) async* {
    final stream = await _connection.open('backup:${arguments.map((a) => ' ${shellQuote(a)}').join()}');
    try {
      yield* stream.input;
    } finally {
      await stream.close();
    }
  }

  /// Sends [archive] (a file from [create]) to the device, which asks its user to confirm, then restores it. Like adb,
  /// it closes the stream once everything was sent and acknowledged; the restore goes on on the device.
  Future<void> restore(Stream<List<int>> archive) async {
    final stream = await _connection.open('restore:');
    // Whatever the device prints is not needed; its failure must not go unheard.
    stream.input.drain<void>().ignore();
    try {
      await for (final chunk in archive) {
        await stream.write(chunk);
      }
      await stream.flush();
    } finally {
      await stream.close();
    }
  }
}
