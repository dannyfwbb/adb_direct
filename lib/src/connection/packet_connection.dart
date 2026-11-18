// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/message.dart';
import '../services/reverse.dart';
import '../stream/adb_stream.dart';
import 'connection.dart';
import 'handshake.dart';
import 'message_link.dart';
import 'options.dart';

/// The service opened to check that the device answers: it does not exist, so adbd refuses it at once without starting
/// anything.
@internal
const String livenessService = 'adb-direct-ping:';

/// A connection that speaks the ADB protocol itself, over TCP or TLS.
@internal
final class PacketConnection extends AdbConnection {
  /// Takes over [_link] after a successful handshake.
  PacketConnection(this._link, this._handshake, this.options) : clock = _link.clock, super.base() {
    _core = _ConnectionCore(this);
    _lastInbound = clock.elapsed;
    _link.route(_core);
    _scheduleLivenessCheck();
  }

  /// The most device-initiated streams open at once; more are refused.
  static const int maxReverseStreams = 256;

  final MessageLink _link;
  final HandshakeResult _handshake;
  late final _ConnectionCore _core;
  final Map<int, StreamEndpoint> _endpoints = {};
  final Map<String, AdbReverseHandler> _reverseTargets = {};
  final Completer<void> _done = Completer<void>();
  int _nextLocalId = 1;
  AdbException? _closeReason;
  Duration _lastInbound = Duration.zero;
  StreamEndpoint? _livenessProbe;
  Timer? _livenessTimer;

  @override
  final AdbClock clock;

  @override
  final AdbConnectOptions options;

  @override
  AdbBanner get device => _handshake.banner;

  @override
  AdbKeyPair? get acceptedKey => _handshake.key;

  @override
  int get protocolVersion => _handshake.protocolVersion;

  @override
  bool get isTls => _handshake.tls;

  @override
  Uint8List? get deviceCertificate => _handshake.deviceCertificate;

  @override
  int get maxPayload => _handshake.maxPayload;

  @override
  bool get delayedAck => _handshake.delayedAck;

  @override
  bool get isClosed => _closeReason != null;

  @override
  AdbException? get closeReason => _closeReason;

  @override
  Future<void> get done => _done.future;

  @override
  AdbStream openStream(String service) => AdbStream(_openEndpoint(service));

  @override
  Future<void> close({bool drain = true}) async {
    if (_closeReason == null) {
      await _link.close(
        const AdbCancelledException('The connection was closed by the caller'),
        drainTimeout: drain ? options.acknowledgementTimeout : Duration.zero,
      );
    }
    return done;
  }

  @override
  void registerReverseTarget(String label, AdbReverseHandler handler) => _reverseTargets[label] = handler;

  @override
  void unregisterReverseTarget(String label) => _reverseTargets.remove(label);

  int? get _ourWindow => delayedAck ? options.receiveWindow : null;

  StreamEndpoint _openEndpoint(String service) {
    if (_closeReason case final reason?) throw reason;
    if (utf8.encode(service).length + 1 > maxPayload) {
      throw ArgumentError.value(service, 'service', 'longer than the payload limit of $maxPayload bytes');
    }

    final endpoint = StreamEndpoint(_core, localId: _allocateId(), service: service);
    _endpoints[endpoint.localId] = endpoint;
    _link.send(AdbMessage.open(localId: endpoint.localId, service: service, window: _ourWindow ?? 0));
    return endpoint;
  }

  void _onMessage(AdbMessage message) {
    _lastInbound = clock.elapsed;
    // Ids are the sender's: arg0 is the device's stream, arg1 ours.
    final (theirs, ours) = (message.arg0, message.arg1);
    switch (message.command) {
      case AdbCommand.okay when theirs != 0 && ours != 0:
        // An open succeeded or a write was taken.
        final endpoint = _endpoints[ours];
        if (endpoint == null) {
          // We no longer know the stream (closed while the device answered): tell the device, as adb does.
          _link.send(AdbMessage.close(localId: ours, remoteId: theirs));
        } else if (endpoint.acceptsFrom(theirs)) {
          endpoint.handleOkay(message);
        }
      case AdbCommand.write when theirs != 0 && ours != 0:
        final endpoint = _endpoints[ours];
        if (endpoint != null && endpoint.acceptsFrom(theirs)) endpoint.handleData(message);
      case AdbCommand.close when ours != 0:
        // The device's id is 0 when it refuses an open. Unknown ids are already closed.
        final endpoint = _endpoints[ours];
        if (endpoint != null && (theirs == 0 || endpoint.acceptsFrom(theirs))) endpoint.handleClose();
      case AdbCommand.open when theirs != 0:
        _onDeviceOpen(message);
      case AdbCommand.connect:
        // A new CNXN means adbd started over (restarted, or switched mode): every stream on this connection is gone.
        _link.fail(const AdbClosedException('The device restarted the connection (new CNXN)'));
      case AdbCommand.auth || AdbCommand.stls || AdbCommand.sync:
        _link.note('Ignored ${message.command.wireName} on an open connection');
      case AdbCommand.okay || AdbCommand.write || AdbCommand.close || AdbCommand.open:
        break; // A zero id where one is needed.
    }
  }

  /// The device opens a stream to us only for reverse forwarding, and only to a target registered here. Anything else
  /// is refused: adb aborts on it, as an unchecked `OPEN` would let a device reach whatever the host can.
  void _onDeviceOpen(AdbMessage open) {
    final target = utf8.decode(open.payload, allowMalformed: true).replaceFirst(RegExp('\u0000+\$'), '');
    final handler = _reverseTargets[target];
    // As adbd: the window must be there exactly when delayed acknowledgements are on.
    final windowAsAgreed = delayedAck == (open.arg1 != 0);
    final reverseStreams = _endpoints.values.where((e) => e.accepted).length;
    if (handler == null || !windowAsAgreed || reverseStreams >= maxReverseStreams) {
      _link
        ..note('Refused a device-initiated OPEN of "$target"')
        ..send(AdbMessage.close(localId: 0, remoteId: open.arg0));
      return;
    }

    final endpoint = StreamEndpoint.accepted(
      _core,
      localId: _allocateId(),
      service: target,
      remoteId: open.arg0,
      window: open.arg1,
    );
    _endpoints[endpoint.localId] = endpoint;
    _link
      ..note('Accepted a reverse connection to "$target"')
      // With delayed acknowledgements our OKAY announces our window.
      ..send(AdbMessage.okay(localId: endpoint.localId, remoteId: open.arg0, acknowledged: _ourWindow));

    final stream = AdbStream(endpoint);
    Future.sync(() => handler(stream)).catchError((Object e) {
      _link.note('A reverse handler for "$target" failed: $e');
      unawaited(stream.close());
    }).ignore();
  }

  void _onLinkClosed(AdbException reason) {
    if (_closeReason != null) return;
    _closeReason = reason;
    _livenessTimer?.cancel();
    final endpoints = _endpoints.values.toList();
    _endpoints.clear();
    for (final endpoint in endpoints) {
      endpoint.handleConnectionEnd(reason);
    }
    _done.complete();
  }

  /// adbd holds acknowledgements back on purpose while a process does not read its input, so an overdue one alone does
  /// not prove the device gone: ask it with the liveness probe. Only a probe without an answer fails the connection.
  void _onAcknowledgementOverdue(StreamEndpoint endpoint) {
    final timeout = options.acknowledgementTimeout;
    if (identical(endpoint, _livenessProbe)) {
      _link.fail(AdbTimeoutException('The device stopped answering (no answer to a liveness check within $timeout)'));
      return;
    }
    _link.note('No acknowledgement on "${endpoint.service}" within $timeout: checking the device');
    _probe();
  }

  void _scheduleLivenessCheck() {
    final interval = options.livenessInterval;
    if (interval == null || _closeReason != null) return;
    final silence = clock.elapsed - _lastInbound;
    _livenessTimer = clock.timer(silence >= interval ? interval : interval - silence, _checkLiveness);
  }

  void _checkLiveness() {
    if (_closeReason != null) return;
    final interval = options.livenessInterval!;
    final userStreams = _endpoints.length - (_livenessProbe == null ? 0 : 1);
    if (userStreams > 0 && clock.elapsed - _lastInbound >= interval) {
      _link.note('Silence for $interval with streams open: checking');
      _probe();
    }
    _scheduleLivenessCheck();
  }

  /// Opens the liveness service unless a check is already running. Any answer (adbd refuses it) proves the device is
  /// there; no answer trips the probe's own acknowledgement timer.
  void _probe() {
    if (_livenessProbe != null || _closeReason != null) return;
    final probe = _livenessProbe = _openEndpoint(livenessService);
    unawaited(probe.done.then((_) => _livenessProbe = null));
  }

  int _allocateId() {
    while (true) {
      final id = _nextLocalId;
      _nextLocalId = id == 0xffffffff ? 1 : id + 1;
      if (!_endpoints.containsKey(id)) return id;
    }
  }
}

/// The connection's side facing the link and the stream endpoints, kept off [AdbConnection]'s public surface.
final class _ConnectionCore implements MessageHandler, StreamHost {
  _ConnectionCore(this._connection);

  final PacketConnection _connection;

  @override
  void onMessage(AdbMessage message) => _connection._onMessage(message);

  @override
  void onLinkClosed(AdbException reason) => _connection._onLinkClosed(reason);

  @override
  void send(AdbMessage message) => _connection._link.send(message);

  @override
  int get maxPayload => _connection.maxPayload;

  @override
  bool get delayedAck => _connection.delayedAck;

  @override
  AdbClock get clock => _connection.clock;

  @override
  Duration get acknowledgementTimeout => _connection.options.acknowledgementTimeout;

  @override
  void endpointFinished(int localId) => _connection._endpoints.remove(localId);

  @override
  void acknowledgementOverdue(StreamEndpoint endpoint) => _connection._onAcknowledgementOverdue(endpoint);
}
