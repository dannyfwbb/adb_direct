// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

/// The source of time and timers for everything that waits.
///
/// Deadlines, stall guards and retries take an [AdbClock] so tests can move time by hand while real sockets keep
/// working. [AdbClock.system] is the default.
abstract interface class AdbClock {
  /// The real clock.
  static const AdbClock system = _SystemClock();

  /// Monotonic time since an arbitrary origin. Only differences matter.
  Duration get elapsed;

  /// Runs [callback] once after [duration].
  Timer timer(Duration duration, void Function() callback);
}

final class _SystemClock implements AdbClock {
  const _SystemClock();

  static final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  Duration get elapsed => _stopwatch.elapsed;

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);
}

/// Waiting on an [AdbClock].
extension AdbClockWaits on AdbClock {
  /// [future]'s outcome, or the error [onTimeout] makes when it takes longer than [timeout].
  Future<T> deadline<T>(Future<T> future, Duration timeout, Object Function() onTimeout) {
    final result = Completer<T>();
    final timer = this.timer(timeout, () {
      if (!result.isCompleted) result.completeError(onTimeout());
    });
    future
        .then(
          (value) {
            if (!result.isCompleted) result.complete(value);
          },
          onError: (Object e, StackTrace s) {
            if (!result.isCompleted) result.completeError(e, s);
          },
        )
        .whenComplete(timer.cancel)
        .ignore();
    return result.future;
  }

  /// Completes after [duration], or as soon as [cancelOn] completes.
  Future<void> sleep(Duration duration, {Future<void>? cancelOn}) {
    final done = Completer<void>();
    void wake() {
      if (!done.isCompleted) done.complete();
    }

    final timer = this.timer(duration, wake);
    cancelOn?.whenComplete(wake).ignore();
    return done.future.whenComplete(timer.cancel);
  }
}
