// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../errors.dart';
import 'byte_queue.dart';

/// Reads exact byte counts from a byte stream, for protocols framed by length.
@internal
final class ByteReader {
  /// Starts reading [input]. [onEnd] makes the error a read throws once [input] has ended (with null) or failed.
  ByteReader(Stream<List<int>> input, {required this.onEnd, this.clock = AdbClock.system}) {
    _subscription = input.listen(
      (data) {
        _buffer.add(data);
        _received += data.length;
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _ended = true;
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
      },
    );
  }

  /// The error for a read past the end; gets the stream's error, or null when it simply ended.
  final AdbException Function(Object? error) onEnd;

  /// The clock read timeouts run on.
  final AdbClock clock;

  late final StreamSubscription<List<int>> _subscription;
  final ByteQueue _buffer = ByteQueue();
  Completer<void>? _waiter;
  int _received = 0;
  Object? _error;
  bool _ended = false;

  /// Exactly [count] bytes. Throws [onEnd]'s error when the stream ends first, and [onTimeout]'s when no byte arrives
  /// for [timeout] (a long read that keeps moving does not time out).
  Future<Uint8List> take(int count, {Duration? timeout, AdbException Function()? onTimeout}) async {
    var timedOut = false;
    Timer? timer;
    void arm(int seen) {
      timer = clock.timer(timeout!, () {
        if (_received != seen) return arm(_received);
        timedOut = true;
        _wake();
      });
    }

    if (timeout != null) arm(_received);
    try {
      while (_buffer.length < count) {
        if (_ended) throw onEnd(_error);
        if (timedOut) throw onTimeout?.call() ?? AdbTimeoutException('No answer within $timeout');
        await (_waiter = Completer<void>()).future;
      }
      return _buffer.take(count);
    } finally {
      timer?.cancel();
    }
  }

  /// Stops reading and hands over what is left: the buffered bytes, whether the stream already ended, and the
  /// subscription for the rest (its handlers are the new owner's to set).
  (Uint8List, bool, StreamSubscription<List<int>>) detach() => (_buffer.take(_buffer.length), _ended, _subscription);

  /// Stops reading.
  Future<void> cancel() => _subscription.cancel();

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }
}
