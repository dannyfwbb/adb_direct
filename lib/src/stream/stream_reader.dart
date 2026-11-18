// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import '../clock.dart';
import '../errors.dart';
import '../protocol/byte_queue.dart';
import 'adb_stream.dart';

/// Reads framed data from an [AdbStream]: exact byte counts, with
/// backpressure and a stall guard.
///
/// Holds about [highWater] bytes between reads: past that the stream is
/// paused, which (through ADB flow control) stops the device. A read that sees no
/// byte for [stallTimeout] fails with [AdbTimeoutException]; the caller
/// decides what to do with the stream.
final class StreamReader {
  /// Starts reading [stream].
  StreamReader(
    this.stream, {
    required this.clock,
    this.stallTimeout = const Duration(seconds: 30),
    this.highWater = 1024 * 1024,
  }) {
    _subscription = stream.input.listen(
      _onData,
      onError: (Object error) {
        _error ??= error is AdbException ? error : AdbClosedException('Stream failed', cause: error);
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
      },
    );
  }

  /// The stream read from.
  final AdbStream stream;

  /// The clock the stall guard runs on.
  final AdbClock clock;

  /// How long a read may wait without any byte arriving.
  final Duration stallTimeout;

  /// Buffered bytes above which the device is paused.
  final int highWater;

  late final StreamSubscription<Uint8List> _subscription;
  final ByteQueue _buffer = ByteQueue();
  int _received = 0;
  Completer<void>? _waiter;
  AdbException? _error;
  bool _ended = false;

  /// Bytes buffered and not yet read.
  int get buffered => _buffer.length;

  /// Whether the stream ended and everything buffered was read.
  bool get isDone => _ended && _buffer.isEmpty;

  /// Reads exactly [count] bytes.
  ///
  /// Throws [AdbClosedException] when the stream ends first (with what the
  /// connection said, if it failed), [AdbTimeoutException] after
  /// [stallTimeout] without progress.
  Future<Uint8List> readExactly(int count) async {
    while (_buffer.length < count) {
      if (_error case final error?) throw error;
      if (_ended) {
        throw AdbClosedException(
          'The stream to "${stream.service}" ended after '
          '${_buffer.length} of $count bytes',
        );
      }
      // More is needed than is buffered: let the device send, even past
      // the high-water mark (a frame larger than it must still complete).
      if (_subscription.isPaused) _subscription.resume();
      await _waitForData();
    }
    final out = _buffer.take(count);
    _resumeIfLow();
    return out;
  }

  /// Stops reading; a read waiting for data fails with
  /// [AdbClosedException].
  Future<void> cancel() {
    _error ??= AdbClosedException('Stopped reading "${stream.service}"');
    _wake();
    return _subscription.cancel();
  }

  /// Bytes received from the stream so far (progress for watchdogs).
  int get received => _received;

  void _onData(Uint8List data) {
    _received += data.length;
    _buffer.add(data);
    if (_buffer.length >= highWater && !_subscription.isPaused) {
      _subscription.pause();
    }
    _wake();
  }

  void _resumeIfLow() {
    if (_subscription.isPaused && _buffer.length < highWater) {
      _subscription.resume();
    }
  }

  Future<void> _waitForData() async {
    final waiter = _waiter = Completer<void>();
    final before = _received;
    var stalled = false;
    final timer = clock.timer(stallTimeout, () {
      stalled = true;
      _wake();
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
    }
    // Stalled means no byte at all during the whole period, even when part
    // of a frame is already buffered.
    if (stalled && _received == before && !_ended && _error == null) {
      throw AdbTimeoutException('No data on "${stream.service}" for $stallTimeout');
    }
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
