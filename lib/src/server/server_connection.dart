// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart';
import '../connection/options.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../services/reverse.dart';
import '../stream/adb_stream.dart';
import 'adb_server.dart';
import 'smart_socket.dart';

/// A connection to one device through the adb server.
///
/// Created by [AdbServer.device]; not meant to be extended.
@internal
final class ServerConnection extends AdbConnection {
  /// Creates it and starts watching the device's state at the server.
  ServerConnection(this._server, this.serial, this.device, this.options) : super.base() {
    _tracking = _server.trackDevices().listen(
      (devices) {
        final now = devices.where((d) => d.serial == serial).firstOrNull;
        if (now == null || !now.isOnline) {
          _fail(AdbClosedException(now == null ? '"$serial" left the adb server' : '"$serial" is ${now.state}'));
        }
      },
      onError: (Object e) => _fail(AdbClosedException('Lost the adb server', cause: e)),
      onDone: () => _fail(const AdbClosedException('Lost the adb server')),
    );
  }

  final AdbServer _server;

  /// The device's serial at the server.
  final String serial;

  final Set<_RelayedStream> _streams = {};
  final Completer<void> _done = Completer<void>();
  AdbException? _closeReason;
  late final StreamSubscription<List<AdbServerDevice>> _tracking;

  @override
  final AdbBanner device;

  @override
  final AdbConnectOptions options;

  @override
  AdbClock get clock => AdbClock.system;

  @override
  AdbKeyPair? get acceptedKey => null;

  @override
  int get protocolVersion => 0x01000001;

  @override
  bool get isTls => false;

  @override
  Uint8List? get deviceCertificate => null;

  /// The longest service name the server's framing carries.
  @override
  int get maxPayload => 0xffff;

  @override
  bool get delayedAck => false;

  @override
  bool get isClosed => _closeReason != null;

  @override
  AdbException? get closeReason => _closeReason;

  @override
  Future<void> get done => _done.future;

  @override
  AdbStream openStream(String service) {
    AdbConnection.checkServiceName(service);
    if (_closeReason case final reason?) throw reason;
    final stream = _RelayedStream(service);
    _streams.add(stream);
    stream.done.then((_) => _streams.remove(stream)).ignore();
    unawaited(stream.start(_server, serial));
    return AdbStream(stream);
  }

  @override
  Future<void> close({bool drain = true}) async {
    if (_closeReason != null) return;
    final streams = _streams.toList();
    _fail(const AdbCancelledException('The connection was closed by the caller'));
    await Future.wait([for (final s in streams) s.done]);
  }

  /// The server connects reverse forwards to local ports itself (`tcp:<port>` targets on this machine); handlers in
  /// code need the ADB protocol here.
  @override
  void registerReverseTarget(String label, AdbReverseHandler handler) {
    if (!RegExp(r'^tcp:\d+$').hasMatch(label)) {
      throw const AdbNotSupportedException(
        'Through an adb server, reverse forwarding reaches local ports on this machine only '
        '(toLocalPort with the default host)',
      );
    }
  }

  @override
  void unregisterReverseTarget(String label) {}

  void _fail(AdbException reason) {
    if (_closeReason != null) return;
    _closeReason = reason;
    // Cancelling while the tracker still connects hands us its failure; the connection is over either way.
    _tracking.cancel().ignore();
    for (final stream in _streams.toList()) {
      stream.finish(reason);
    }
    _done.complete();
  }
}

/// A stream relayed by the server: a socket that asked for `host:transport:<serial>`, then for the service.
final class _RelayedStream implements StreamCore {
  _RelayedStream(this.service) {
    _opened.future.ignore();
  }

  @override
  final String service;

  final Completer<void> _opened = Completer<void>();
  final Completer<void> _done = Completer<void>();
  late final StreamController<Uint8List> _input = StreamController<Uint8List>(onCancel: close);
  final StreamController<int> _acks = StreamController<int>.broadcast();
  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  AdbException? _closeReason;
  bool _closed = false;
  int _written = 0;
  int _flushed = 0;
  Future<void> _writes = Future.value();

  /// Asks the server for the device, then for the service, and takes the socket over as the stream.
  Future<void> start(AdbServer server, String serial) async {
    SmartSocket? smart;
    try {
      smart = await SmartSocket.open(server.host, server.port, server.timeout);
      await smart.request('host:transport:$serial', transport: true);
      await smart.request(service);
    } on Object catch (e) {
      smart?.destroy();
      finish(switch (e) {
        AdbServiceUnavailableException() => AdbServiceUnavailableException(
          'The device refused to open "$service": ${e.message}',
          service: service,
        ),
        AdbException() => e,
        _ => AdbProtocolException('Opening "$service" failed: $e', cause: e),
      });
      return;
    }
    if (_closed) {
      smart.destroy();
      return;
    }

    final (socket, rest, ended, subscription) = smart.detach();
    _socket = socket;
    _subscription = subscription;
    if (rest.isNotEmpty) _input.add(rest);
    _opened.complete();
    if (ended) {
      finish(null);
      return;
    }
    subscription
      ..onData((data) {
        if (!_input.isClosed) _input.add(data is Uint8List ? data : Uint8List.fromList(data));
      })
      ..onError((Object e) => finish(AdbClosedException('The relayed stream failed', cause: e)))
      ..onDone(() => finish(null));
    _input
      ..onPause = subscription.pause
      ..onResume = subscription.resume;
  }

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> get opened => _opened.future;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  AdbException? get closeReason => _closeReason;

  /// What the server's socket has taken: the device's own acknowledgements stay between the server and the device.
  @override
  int get acknowledgedBytes => _flushed;

  @override
  Stream<int> get acknowledgements => _acks.stream;

  @override
  Future<void> write(List<int> data) {
    if (_closed) return Future.error(_closedError);
    if (data.isEmpty) return Future.value();

    final copy = Uint8List.fromList(data);
    final target = _written += copy.length;
    return _writes = _writes.then((_) async {
      await opened;
      final socket = _socket;
      if (socket == null || _closed) throw _closedError;
      socket.add(copy);
      await socket.flush();
      _flushed = target;
      if (!_acks.isClosed) _acks.add(_flushed);
    });
  }

  @override
  Future<void> flush() => _writes;

  @override
  Future<void> close() async => finish(null);

  AdbException get _closedError => _closeReason ?? AdbCancelledException('The stream to "$service" is closed');

  /// Ends the stream: normally when [reason] is null, else failed (the connection ended under it, say).
  void finish(AdbException? reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    if (!_opened.isCompleted) {
      _opened.completeError(reason ?? AdbCancelledException('"$service" was closed while opening'));
    }
    unawaited(_subscription?.cancel());
    if (reason != null && reason is! AdbServiceUnavailableException) _input.addError(reason);
    unawaited(_input.close());
    unawaited(_acks.close());
    _socket?.destroy();
    if (!_done.isCompleted) _done.complete();
  }
}
