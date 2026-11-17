// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import '../clock.dart';

/// Calls [onStall] once when [progress] has not changed for [timeout].
///
/// [progress] is any number that grows while work moves (bytes sent,
/// acknowledged, received). It is sampled four times per [timeout], so a
/// stall is noticed between [timeout] and 1.25 × [timeout] after the last
/// movement.
final class ProgressWatchdog {
  /// Starts watching.
  ProgressWatchdog({
    required this.clock,
    required this.timeout,
    required this.progress,
    required this.onStall,
  }) : _last = progress(),
       _lastMove = clock.elapsed {
    _schedule();
  }

  /// The clock samples run on.
  final AdbClock clock;

  /// How long [progress] may stay still.
  final Duration timeout;

  /// The value watched.
  final int Function() progress;

  /// Called once on a stall.
  final void Function() onStall;

  int _last;
  Duration _lastMove;
  Timer? _timer;
  bool _stalled = false;

  /// Whether [onStall] was called.
  bool get stalled => _stalled;

  /// Stops watching.
  void stop() => _timer?.cancel();

  void _schedule() {
    _timer = clock.timer(timeout ~/ 4, () {
      final now = progress();
      if (now != _last) {
        _last = now;
        _lastMove = clock.elapsed;
      } else if (clock.elapsed - _lastMove >= timeout) {
        _stalled = true;
        onStall();
        return;
      }
      _schedule();
    });
  }
}
