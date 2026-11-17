// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/message.dart';
import '../services/shell.dart';
import '../stream/adb_stream.dart';
import '../trace.dart';
import '../transport/tcp_transport.dart';
import 'handshake.dart';
import 'message_link.dart';
import 'options.dart';

/// The service opened to check that the device answers: it does not exist,
/// so adbd refuses it at once without starting anything.
@internal
const String livenessService = 'adb-direct-ping:';

/// A connection to adbd on a device.
///
/// Open one with [connect]; then open streams to services with [open], or
/// use the service helpers such as [shell]. Many streams can be open at
/// once over one connection.
///
/// The connection ends when either side closes it or anything fails; every
/// open stream and pending call then fails with the same [closeReason].
final class AdbConnection {
  AdbConnection._(this._link, this._handshake, this._options)
    : clock = _link.clock {
    _core = _ConnectionCore(this);
    _lastInbound = clock.elapsed;
    _link.route(_core);
    _scheduleLivenessCheck();
  }

  /// Connects to adbd at [host]:[port] (5555 for classic network debugging)
  /// and authenticates with [key], then [extraKeys] in turn.
  ///
  /// When the device trusts none of them and [AdbConnectOptions.allowPrompt]
  /// is set (the default), [key]'s public key is offered and the device
  /// shows "Allow debugging?"; [onWaitingForApproval] is called then, and
  /// the call waits up to [AdbConnectOptions.approvalTimeout] for the user.
  ///
  /// Throws [AdbUnreachableException], [AdbRefusedException],
  /// [AdbUnauthorizedException], [AdbTimeoutException],
  /// [AdbProtocolException], or [AdbNotSupportedException] for a TLS
  /// (wireless debugging) port; [ArgumentError] for invalid [options].
  static Future<AdbConnection> connect(
    Object host,
    int port, {
    required AdbKeyPair key,
    List<AdbKeyPair> extraKeys = const [],
    AdbConnectOptions options = const AdbConnectOptions(),
    void Function()? onWaitingForApproval,
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    options.validate();
    final transport = await TcpTransport.connect(
      host,
      port,
      timeout: options.connectTimeout,
    );
    final link = MessageLink(transport, clock: clock, tracer: tracer)..start();
    try {
      final result = await Handshake(
        link,
        keys: [key, ...extraKeys],
        options: options,
        onWaitingForApproval: onWaitingForApproval,
      ).run();
      return AdbConnection._(link, result, options);
    } on Object catch (e) {
      link.fail(
        e is AdbException
            ? e
            : AdbCancelledException('The handshake was abandoned', cause: e),
      );
      rethrow;
    }
  }

  final MessageLink _link;
  final HandshakeResult _handshake;
  final AdbConnectOptions _options;
  late final _ConnectionCore _core;
  final Map<int, StreamEndpoint> _endpoints = {};
  final Completer<void> _done = Completer<void>();
  int _nextLocalId = 1;
  AdbException? _closeReason;
  Duration _lastInbound = Duration.zero;
  StreamEndpoint? _livenessProbe;
  Timer? _livenessTimer;

  /// The clock deadlines run on.
  final AdbClock clock;

  /// What the device said about itself: state, product, model, features.
  AdbBanner get device => _handshake.banner;

  /// The key the device accepted, or null if it asked for none.
  AdbKeyPair? get acceptedKey => _handshake.key;

  /// The negotiated protocol version.
  int get protocolVersion => _handshake.protocolVersion;

  /// The largest payload either side sends in one message.
  int get maxPayload => _handshake.maxPayload;

  /// Whether delayed acknowledgements are in use on this connection.
  bool get delayedAck => _handshake.delayedAck;

  /// Whether the device lists [feature] (it is used only if this library
  /// announced it too).
  bool supports(AdbFeature feature) => device.supports(feature);

  /// Whether the connection has ended.
  bool get isClosed => _closeReason != null;

  /// Why the connection ended, or null while it is open.
  AdbException? get closeReason => _closeReason;

  /// Completes when the connection has ended, for any reason. Never fails;
  /// see [closeReason].
  Future<void> get done => _done.future;

  /// Shell commands.
  late final AdbShell shell = AdbShell(this);

  /// Opens a stream to [service] on the device, such as `shell:ls` or
  /// `sync:`.
  ///
  /// Completes when the device accepted it. Throws
  /// [AdbServiceUnavailableException] when the device refuses, and the
  /// connection's [closeReason] when it ends first.
  Future<AdbStream> open(String service) async {
    final stream = openStream(service);
    await stream.opened;
    return stream;
  }

  /// Like [open], but returns the stream at once, before the device
  /// answered; [AdbStream.opened] tells how the open went. Writes made
  /// before then wait.
  AdbStream openStream(String service) => AdbStream(_openEndpoint(service));

  /// Closes the connection. Open streams end; their pending calls fail with
  /// [AdbCancelledException]. What is queued is sent first, for at most
  /// [AdbConnectOptions.acknowledgementTimeout].
  Future<void> close() async {
    if (_closeReason == null) {
      await _link.close(
        const AdbCancelledException('The connection was closed by the caller'),
        drainTimeout: _options.acknowledgementTimeout,
      );
    }
    return done;
  }

  @override
  String toString() =>
      'AdbConnection(${device.model ?? device.systemType}'
      '${isClosed ? ', closed' : ''})';

  StreamEndpoint _openEndpoint(String service) {
    if (_closeReason case final reason?) throw reason;
    final payloadLength = utf8.encode(service).length + 1;
    if (payloadLength > maxPayload) {
      throw ArgumentError.value(
        service,
        'service',
        'longer than the payload limit of $maxPayload bytes',
      );
    }
    final endpoint = StreamEndpoint(
      _core,
      localId: _allocateId(),
      service: service,
    );
    _endpoints[endpoint.localId] = endpoint;
    _link.send(
      AdbMessage.open(
        localId: endpoint.localId,
        service: service,
        window: delayedAck ? _options.receiveWindow : 0,
      ),
    );
    return endpoint;
  }

  void _onMessage(AdbMessage message) {
    _lastInbound = clock.elapsed;
    switch (message.command) {
      case AdbCommand.okay:
        // OKAY(remote id, our id): an open succeeded or a write was taken.
        if (message.arg0 == 0 || message.arg1 == 0) return;
        final endpoint = _endpoints[message.arg1];
        if (endpoint == null) {
          // We no longer know the stream (closed while the device answered):
          // tell the device, as adb does.
          _link.send(
            AdbMessage.close(localId: message.arg1, remoteId: message.arg0),
          );
        } else if (endpoint.acceptsFrom(message.arg0)) {
          endpoint.handleOkay(message);
        }
      case AdbCommand.write:
        if (message.arg0 == 0 || message.arg1 == 0) return;
        final endpoint = _endpoints[message.arg1];
        if (endpoint != null && endpoint.acceptsFrom(message.arg0)) {
          endpoint.handleData(message);
        }
      case AdbCommand.close:
        // CLSE(remote id or 0, our id). Unknown ids: already closed, ignore.
        if (message.arg1 == 0) return;
        final endpoint = _endpoints[message.arg1];
        if (endpoint != null &&
            (message.arg0 == 0 || endpoint.acceptsFrom(message.arg0))) {
          endpoint.handleClose();
        }
      case AdbCommand.open:
        // The device opens a stream to us only for reverse forwarding, which
        // nothing has set up: refuse it.
        if (message.arg0 != 0) {
          _link
            ..note(
              'Refused a device-initiated OPEN of '
              '"${utf8.decode(message.payload, allowMalformed: true)}"',
            )
            ..send(AdbMessage.close(localId: 0, remoteId: message.arg0));
        }
      case AdbCommand.connect:
        // A new CNXN means adbd started over (restarted, or switched mode):
        // every stream on this connection is gone.
        _link.fail(
          const AdbClosedException(
            'The device restarted the connection (new CNXN)',
          ),
        );
      case AdbCommand.auth || AdbCommand.stls || AdbCommand.sync:
        _link.note('Ignored ${message.command.wireName} on an open connection');
    }
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

  /// An acknowledgement is overdue. adbd holds acknowledgements back on
  /// purpose while a process does not read its input, so this alone does
  /// not prove the device gone: ask it with the liveness probe. Only a probe
  /// without an answer fails the connection.
  void _onAcknowledgementOverdue(StreamEndpoint endpoint) {
    if (identical(endpoint, _livenessProbe)) {
      _link.fail(
        AdbTimeoutException(
          'The device stopped answering (no answer to a liveness check '
          'within ${_options.acknowledgementTimeout})',
        ),
      );
      return;
    }
    _link.note(
      'No acknowledgement on "${endpoint.service}" within '
      '${_options.acknowledgementTimeout}: checking the device',
    );
    _probe();
  }

  void _scheduleLivenessCheck() {
    final interval = _options.livenessInterval;
    if (interval == null || _closeReason != null) return;
    final silence = clock.elapsed - _lastInbound;
    final wait = silence >= interval ? interval : interval - silence;
    _livenessTimer = clock.timer(wait, _checkLiveness);
  }

  void _checkLiveness() {
    if (_closeReason != null) return;
    final interval = _options.livenessInterval!;
    final userStreams = _endpoints.length - (_livenessProbe == null ? 0 : 1);
    if (userStreams > 0 && clock.elapsed - _lastInbound >= interval) {
      _link.note('Silence for $interval with streams open: checking');
      _probe();
    }
    _scheduleLivenessCheck();
  }

  /// Opens the liveness service unless a check is already running. Any
  /// answer (adbd refuses it) proves the device is there; no answer trips
  /// the probe's own acknowledgement timer.
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

/// The connection's side facing the link and the stream endpoints, kept off
/// [AdbConnection]'s public surface.
final class _ConnectionCore implements MessageHandler, StreamHost {
  _ConnectionCore(this._connection);

  final AdbConnection _connection;

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
  Duration get acknowledgementTimeout =>
      _connection._options.acknowledgementTimeout;

  @override
  void endpointFinished(int localId) => _connection._endpoints.remove(localId);

  @override
  void acknowledgementOverdue(StreamEndpoint endpoint) =>
      _connection._onAcknowledgementOverdue(endpoint);
}
