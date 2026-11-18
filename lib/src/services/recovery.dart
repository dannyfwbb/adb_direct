// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import '../protocol/byte_queue.dart';
import '../stream/adb_stream.dart';
import 'sync.dart';

/// Recovery and rescue mode: `adb sideload`.
final class AdbRecovery {
  /// Creates the namespace.
  @internal
  AdbRecovery(this._connection);

  final AdbConnection _connection;

  /// The block size offered to the device (adb's).
  static const int blockSize = 64 * 1024;

  /// Serves [package] (an OTA zip) to a device in recovery's "Apply update from ADB" (or rescue mode with [rescue]), as
  /// `adb sideload` does: the device asks for blocks in any order, often reading the file about twice, until it says it
  /// is done.
  ///
  /// [onProgress] reports bytes served and the file size (the served total passes the size). Devices before Android 4.4
  /// take the whole file at once instead. Throws [AdbServiceUnavailableException] when the device reports a failed
  /// install.
  Future<void> sideload(File package, {bool rescue = false, AdbProgress? onProgress}) async {
    final file = await package.open();
    try {
      final size = await file.length();
      final service = '${rescue ? 'rescue-install' : 'sideload-host'}:$size:$blockSize';
      final AdbStream stream;
      try {
        stream = await _connection.open(service);
      } on AdbServiceUnavailableException {
        // As adb: the old method only for what fits its 32-bit size.
        if (rescue || size > 0x7fffffff) rethrow;
        return await _legacy(file, size, onProgress);
      }
      await serveBlocks(stream, file, size, onProgress);
    } finally {
      await file.close();
    }
  }

  Future<void> _legacy(RandomAccessFile file, int size, AdbProgress? onProgress) async {
    final stream = await _connection.open('sideload:$size');
    final reading = stream.input.drain<void>();
    reading.ignore();
    try {
      await file.setPosition(0);
      var sent = 0;
      while (sent < size) {
        final chunk = await file.read(blockSize);
        if (chunk.isEmpty) break;
        await stream.write(chunk);
        sent += chunk.length;
        onProgress?.call(sent, size);
      }
      await stream.flush();
      await reading;
    } finally {
      await stream.close();
    }
  }
}

/// The `sideload-host` exchange: the device sends eight decimal digits (a block number) or `DONEDONE` / `FAILFAIL`;
/// each block is answered with its bytes (the last one short).
@internal
Future<void> serveBlocks(AdbStream stream, RandomAccessFile file, int size, AdbProgress? onProgress) async {
  final requests = ByteQueue();
  final input = StreamIterator(stream.input);
  var served = 0;
  try {
    while (true) {
      while (requests.length < 8) {
        if (!await input.moveNext()) {
          throw const AdbClosedException('The device ended the sideload before it was done');
        }
        requests.add(input.current);
      }
      final request = ascii.decode(requests.take(8), allowInvalid: true);
      if (request == 'DONEDONE') return;
      if (request == 'FAILFAIL') {
        throw const AdbServiceUnavailableException(
          'The device reported the sideload as failed',
          service: 'sideload-host',
        );
      }
      final block = RegExp(r'^[0-9]{8}$').hasMatch(request) ? int.parse(request) : null;
      final offset = block == null ? -1 : block * AdbRecovery.blockSize;
      if (block == null || offset >= size) {
        throw AdbProtocolException('The device asked for block "$request"');
      }
      await file.setPosition(offset);
      final length = offset + AdbRecovery.blockSize > size ? size - offset : AdbRecovery.blockSize;
      final data = Uint8List(length);
      await file.readInto(data);
      await stream.write(data);
      served += length;
      onProgress?.call(served, size);
    }
  } finally {
    await input.cancel();
    await stream.close();
  }
}
