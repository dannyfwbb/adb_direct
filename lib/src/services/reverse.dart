// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import '../stream/adb_stream.dart';
import 'answers.dart';
import 'pipe.dart';

/// Receives each connection made to a reverse forward on the device. It
/// may be asynchronous; when it fails, the stream is closed.
typedef AdbReverseHandler = FutureOr<void> Function(AdbStream stream);

/// One reverse forward, as [AdbReverse] set it up.
final class AdbReverseForward {
  AdbReverseForward._(this._reverse, this.deviceSpec, this.hostLabel);

  final AdbReverse _reverse;

  /// What listens on the device (`tcp:18080`), with the port filled in when
  /// it was `tcp:0`.
  final String deviceSpec;

  /// The name the device uses for our side (`tcp:19000` for
  /// [AdbReverse.toLocalPort]); `adb reverse --list` shows it.
  final String hostLabel;

  /// The device port, for a `tcp:` spec.
  int? get devicePort => deviceSpec.startsWith('tcp:')
      ? int.tryParse(deviceSpec.substring(4))
      : null;

  /// Removes this forward on the device.
  Future<void> remove() => _reverse.remove(deviceSpec);

  @override
  String toString() => 'AdbReverseForward($deviceSpec → $hostLabel)';
}

/// A reverse forward the device reports: what listens there, and the name
/// of the host side.
@immutable
final class AdbReverseEntry {
  /// Creates one.
  const AdbReverseEntry(this.deviceSpec, this.hostLabel);

  /// What listens on the device.
  final String deviceSpec;

  /// The host side's name.
  final String hostLabel;

  @override
  bool operator ==(Object other) =>
      other is AdbReverseEntry &&
      other.deviceSpec == deviceSpec &&
      other.hostLabel == hostLabel;

  @override
  int get hashCode => Object.hash(deviceSpec, hostLabel);

  @override
  String toString() => '$deviceSpec → $hostLabel';
}

/// Reverse forwarding (`adb reverse`): something on the device connects to
/// a port (or socket) there, and the connection arrives here.
///
/// Forwards live as long as this connection. The device may open streams
/// to us only for a forward set up here; any other `OPEN` it sends is
/// refused.
final class AdbReverse {
  /// Creates the namespace.
  @internal
  AdbReverse(this._connection);

  final AdbConnection _connection;
  int _nextLabel = 1;

  /// Listens on the device at [deviceSpec] (`tcp:8080`, `tcp:0` for any
  /// free port, `localabstract:name`, …) and calls [onConnection] with a
  /// stream for each connection made to it. With [rebind] false an
  /// existing forward on [deviceSpec] is an error instead of being
  /// replaced.
  ///
  /// Throws [AdbServiceUnavailableException] when the device refuses (a
  /// bad spec, a port in use, an existing forward without [rebind]).
  Future<AdbReverseForward> add(
    String deviceSpec,
    AdbReverseHandler onConnection, {
    bool rebind = true,
  }) => _add(
    deviceSpec,
    'localabstract:adb_direct_reverse_${_nextLabel++}',
    onConnection,
    rebind: rebind,
  );

  /// Like [add], with each connection copied to a new TCP connection to
  /// [host]:[port] here, as `adb reverse <device> tcp:<port>` does. A local
  /// connection that fails closes the device's connection.
  Future<AdbReverseForward> toLocalPort(
    String deviceSpec,
    int port, {
    Object host = '127.0.0.1',
    bool rebind = true,
  }) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'not a TCP port');
    }
    // adb's own name for the default; another host gets its own name, so
    // two targets never share one.
    final label = host == '127.0.0.1' ? 'tcp:$port' : 'tcp:$port:$host';
    return _add(deviceSpec, label, (stream) async {
      final Socket socket;
      try {
        socket = await Socket.connect(host, port);
      } on Object {
        await stream.close();
        return;
      }
      await pipe(stream, socket);
    }, rebind: rebind);
  }

  /// The reverse forwards the device holds for this connection.
  Future<List<AdbReverseEntry>> list() async {
    final raw = await readAll(_connection, 'reverse:list-forward');
    final text = SmartAnswer.hexPrefixed(String.fromCharCodes(raw));
    return [
      for (final line in text.split('\n'))
        if (line.trim().split(' ') case [_, final device, final host])
          AdbReverseEntry(device, host),
    ];
  }

  /// Removes the forward on [deviceSpec]. Throws
  /// [AdbServiceUnavailableException] when there is none.
  Future<void> remove(String deviceSpec) async {
    await _command('reverse:killforward:$deviceSpec');
    _release(_labels.remove(deviceSpec));
  }

  /// Removes every forward of this connection.
  Future<void> removeAll() async {
    await _command('reverse:killforward-all');
    final labels = _labels.values.toSet();
    _labels.clear();
    labels.forEach(_release);
  }

  /// Device spec → our label, for what this object set up.
  final Map<String, String> _labels = {};

  /// Stops accepting [label] unless another forward still uses it.
  void _release(String? label) {
    if (label != null && !_labels.containsValue(label)) {
      _connection.unregisterReverseTarget(label);
    }
  }

  Future<AdbReverseForward> _add(
    String deviceSpec,
    String label,
    AdbReverseHandler onConnection, {
    required bool rebind,
  }) async {
    if (deviceSpec.contains(';') || deviceSpec.isEmpty) {
      throw ArgumentError.value(deviceSpec, 'deviceSpec', 'is not a spec');
    }
    // Registered first: the device may connect as soon as it answers.
    _connection.registerReverseTarget(label, onConnection);
    final SmartAnswer answer;
    try {
      answer = await _command(
        'reverse:forward:${rebind ? '' : 'norebind:'}$deviceSpec;$label',
      );
    } on Object {
      _release(label);
      rethrow;
    }
    // tcp:0: the device answers with the port it chose.
    final actual = deviceSpec == 'tcp:0' && answer.text.isNotEmpty
        ? 'tcp:${answer.text}'
        : deviceSpec;
    // A rebind replaces what was there: its target is no longer accepted.
    final previous = _labels[actual];
    _labels[actual] = label;
    if (previous != label) _release(previous);
    return AdbReverseForward._(this, actual, label);
  }

  Future<SmartAnswer> _command(String service) async {
    final answer = SmartAnswer.parse(await readAll(_connection, service));
    if (!answer.ok) {
      throw AdbServiceUnavailableException(
        'The device refused "$service": ${answer.text}',
        service: service,
      );
    }
    return answer;
  }
}
