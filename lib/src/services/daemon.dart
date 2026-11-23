// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart';
import '../errors.dart';
import 'answers.dart';

/// What a daemon service did.
enum AdbDaemonOutcome {
  /// adbd is restarting (or the device rebooting): this connection ends; [AdbConnection.waitFor] connects again.
  restarting,

  /// Nothing to do (`adbd is already running as root`).
  unchanged,

  /// The device refused (`adbd cannot run as root in production builds`).
  refused,

  /// The service ran and printed something; read [AdbDaemonAnswer.output].
  done,
}

/// The answer of a daemon service.
@immutable
final class AdbDaemonAnswer {
  /// Creates one.
  const AdbDaemonAnswer(this.outcome, this.output);

  /// What happened.
  final AdbDaemonOutcome outcome;

  /// adbd's exact text.
  final String output;

  /// Whether this connection is over.
  bool get restarting => outcome == AdbDaemonOutcome.restarting;

  @override
  String toString() => 'AdbDaemonAnswer($outcome, ${output.trim()})';
}

/// Services that change adbd itself or the device: `adb root`, `unroot`, `remount`, `reboot`, `tcpip`, `usb`,
/// `disable-verity`, `enable-verity`.
///
/// Those that restart adbd end this connection: the answer says [AdbDaemonOutcome.restarting] and the connection is
/// closed by then. Connect again with [AdbConnection.waitFor].
///
/// A service that stays silent past its `timeout` gets its stream closed and the call throws [AdbTimeoutException],
/// unless what it printed already tells the outcome. Output past 1 MiB is an [AdbCommandException].
final class AdbDaemon {
  /// Creates the namespace.
  @internal
  AdbDaemon(this._connection);

  final AdbConnection _connection;

  /// Restarts adbd as root (userdebug and eng builds, most emulators).
  Future<AdbDaemonAnswer> root({Duration timeout = _shortTimeout}) => _run('root:', timeout, const {
    'restarting adbd as root': AdbDaemonOutcome.restarting,
    'already running as root': AdbDaemonOutcome.unchanged,
    'cannot run as root': AdbDaemonOutcome.refused,
  });

  /// Restarts adbd as the shell user.
  Future<AdbDaemonAnswer> unroot({Duration timeout = _shortTimeout}) => _run('unroot:', timeout, const {
    'restarting adbd as non root': AdbDaemonOutcome.restarting,
    'not running as root': AdbDaemonOutcome.unchanged,
  });

  /// Restarts adbd listening on TCP [port] (5555 is the usual one).
  Future<AdbDaemonAnswer> tcpip(int port, {Duration timeout = _shortTimeout}) {
    if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port', 'not a TCP port');
    return _run('tcpip:$port', timeout, const {'restarting in TCP mode': AdbDaemonOutcome.restarting});
  }

  /// Restarts adbd on USB only. Over the network that ends the device's network debugging until someone turns it on
  /// again on the device or over USB.
  Future<AdbDaemonAnswer> usb({Duration timeout = _shortTimeout}) =>
      _run('usb:', timeout, const {'restarting in USB mode': AdbDaemonOutcome.restarting});

  /// Remounts the system partitions read-write (root; may need [disableVerity] and a reboot first, which its output
  /// says).
  ///
  /// [AdbDaemonOutcome.refused] for the refusals adb prints (not root, a locked bootloader, a user build, no such
  /// tool); otherwise [AdbDaemonOutcome.done], and [AdbDaemonAnswer.output] says what happened.
  Future<AdbDaemonAnswer> remount({Duration timeout = _longTimeout}) => _run('remount:', timeout, _refusals);

  /// Turns dm-verity off (root, userdebug); takes effect after a reboot. Outcomes as [remount].
  Future<AdbDaemonAnswer> disableVerity({Duration timeout = _longTimeout}) =>
      _run('disable-verity:', timeout, _refusals);

  /// Turns dm-verity on again; takes effect after a reboot. Outcomes as [remount].
  Future<AdbDaemonAnswer> enableVerity({Duration timeout = _longTimeout}) => _run('enable-verity:', timeout, _refusals);

  static const Duration _shortTimeout = Duration(seconds: 30);

  /// Remounting and changing verity touch partitions, which takes a while on slow storage.
  static const Duration _longTimeout = Duration(minutes: 2);

  static const int _maxOutput = 1024 * 1024;

  static const Map<String, AdbDaemonOutcome> _refusals = {
    'not running as root': AdbDaemonOutcome.refused,
    'must be bootloader unlocked': AdbDaemonOutcome.refused,
    'USER build': AdbDaemonOutcome.refused,
    'inaccessible or not found': AdbDaemonOutcome.refused,
  };

  /// Reboots the device; [target] is `bootloader`, `recovery`, `sideload`, `sideload-auto-reboot`, `fastboot`, or null
  /// for a normal reboot. The connection ends; a device on the network comes back after it booted and its network is
  /// up.
  Future<AdbDaemonAnswer> reboot([String? target]) async {
    if (target != null && !RegExp(r'^[a-z0-9,_-]+$').hasMatch(target)) {
      throw ArgumentError.value(target, 'target', 'not a reboot target');
    }
    if (_connection.closeReason case final reason?) throw reason;
    try {
      // A device that loses power sends nothing more; do not wait forever.
      await readAll(_connection, 'reboot:${target ?? ''}', timeout: const Duration(seconds: 10));
    } on AdbClosedException {
      // The device went down before closing the stream.
    } on AdbTimeoutException {
      // Nothing came back: it is going down or gone.
    }
    await _connection.close(drain: false);
    return const AdbDaemonAnswer(AdbDaemonOutcome.restarting, '');
  }

  Future<AdbDaemonAnswer> _run(String service, Duration timeout, Map<String, AdbDaemonOutcome> outcomes) async {
    final stream = _connection.openStream(service);

    // adbd may restart before it closes the stream: keep what arrived.
    final bytes = BytesBuilder(copy: false);
    var cutOff = false;
    var tooLong = false;
    var timedOut = false;

    Future<void> read() async {
      await stream.opened;
      try {
        await for (final chunk in stream.input) {
          bytes.add(chunk);
          if (bytes.length > _maxOutput) {
            tooLong = true;
            break;
          }
        }
      } on AdbException {
        cutOff = true;
      }
    }

    AdbTimeoutException? timeoutError;
    try {
      await _connection.clock.deadline(read(), timeout, () {
        timedOut = true;
        unawaited(stream.close());
        return AdbTimeoutException('"$service" did not finish within $timeout');
      });
    } on AdbServiceUnavailableException {
      throw AdbNotSupportedException('The device has no "$service" service');
    } on AdbTimeoutException catch (e) {
      if (!timedOut) rethrow;
      timeoutError = e;
    }

    final output = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    if (tooLong) {
      throw AdbCommandException('"$service" printed more than $_maxOutput B', command: service, output: output);
    }
    // Silence after an answer that already says what happened is still that answer.
    if (timeoutError != null && !outcomes.keys.any(output.contains)) throw timeoutError;
    var outcome =
        outcomes.entries.where((e) => output.contains(e.key)).map((e) => e.value).firstOrNull ?? AdbDaemonOutcome.done;
    if (cutOff && outcome == AdbDaemonOutcome.done && outcomes.containsValue(AdbDaemonOutcome.restarting)) {
      // A service that restarts adbd, cut off before it answered.
      outcome = AdbDaemonOutcome.restarting;
    }
    if (outcome == AdbDaemonOutcome.restarting) {
      // adbd is going away; do not wait on it.
      await _connection.close(drain: false);
    }
    return AdbDaemonAnswer(outcome, output);
  }
}
