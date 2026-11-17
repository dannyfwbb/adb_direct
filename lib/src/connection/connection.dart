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
import '../services/backup.dart';
import '../services/daemon.dart';
import '../services/debug.dart';
import '../services/forward.dart';
import '../services/packages.dart';
import '../services/recovery.dart';
import '../services/reverse.dart';
import '../services/shell.dart';
import '../services/sync.dart';
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
abstract base class AdbConnection {
  /// For the implementations in this package.
  @internal
  AdbConnection.base();

  /// Connects to adbd at [host]:[port] (5555 for classic network debugging)
  /// and authenticates with [key], then [extraKeys] in turn.
  ///
  /// When the device trusts none of them and [AdbConnectOptions.allowPrompt]
  /// is set (the default), [key]'s public key is offered and the device
  /// shows "Allow debugging?"; [onWaitingForApproval] is called then, and
  /// the call waits up to [AdbConnectOptions.approvalTimeout] for the user.
  ///
  /// When [cancelOn] completes before the connection is up (the user backed
  /// out of "Allow debugging?", say), the attempt stops at once, the socket
  /// is closed, and the call throws [AdbCancelledException].
  ///
  /// Throws [AdbUnreachableException], [AdbRefusedException],
  /// [AdbUnauthorizedException], [AdbTimeoutException],
  /// [AdbProtocolException], [AdbCancelledException], or
  /// [AdbNotSupportedException] for a TLS (wireless debugging) port;
  /// [ArgumentError] for invalid [options].
  static Future<AdbConnection> connect(
    Object host,
    int port, {
    required AdbKeyPair key,
    List<AdbKeyPair> extraKeys = const [],
    AdbConnectOptions options = const AdbConnectOptions(),
    void Function()? onWaitingForApproval,
    Future<void>? cancelOn,
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    options.validate();
    // Classic ports try every key in one handshake. A TLS port takes one
    // key per TLS session, so a key the device does not trust costs a new
    // connection to try the next.
    for (var tlsKey = 0; ; tlsKey++) {
      try {
        return await _attempt(
          host,
          port,
          keys: [key, ...extraKeys],
          tlsKey: tlsKey,
          options: options,
          onWaitingForApproval: onWaitingForApproval,
          cancelOn: cancelOn,
          clock: clock,
          tracer: tracer,
        );
      } on TlsKeyRejected catch (e) {
        if (tlsKey + 1 < 1 + extraKeys.length) continue;
        throw AdbUnauthorizedException(
          'The device closed the TLS session before CNXN: most likely it '
          'does not trust the key (on a wireless debugging port, pair it '
          'first), or the connection dropped',
          cause: e.cause,
        );
      }
    }
  }

  /// Connects to a device that is coming back: after
  /// [AdbDaemon.reboot], [AdbDaemon.root], [AdbDaemon.tcpip] and the like,
  /// or a device that is still booting. Retries [connect] with a pause that
  /// grows from 250 ms to 2 s until it succeeds or [timeout] passes.
  ///
  /// Only "not there yet" failures are retried (unreachable, refused,
  /// closed, timeouts, a garbled exchange while adbd starts). A device that
  /// answers and refuses the key fails at once with
  /// [AdbUnauthorizedException]. On timeout the last failure is thrown;
  /// [cancelOn] stops waiting with [AdbCancelledException].
  static Future<AdbConnection> waitFor(
    Object host,
    int port, {
    required AdbKeyPair key,
    List<AdbKeyPair> extraKeys = const [],
    AdbConnectOptions options = const AdbConnectOptions(),
    Duration timeout = const Duration(minutes: 2),
    Future<void>? cancelOn,
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    final deadline = clock.elapsed + timeout;
    var cancelled = false;
    Completer<void>? pause;
    cancelOn
        ?.then(
          (_) {
            cancelled = true;
            pause?.complete();
          },
          onError: (Object _) {
            cancelled = true;
            pause?.complete();
          },
        )
        .ignore();
    var delay = const Duration(milliseconds: 250);
    while (true) {
      if (cancelled) {
        throw const AdbCancelledException(
          'Waiting for the device was cancelled',
        );
      }
      try {
        return await connect(
          host,
          port,
          key: key,
          extraKeys: extraKeys,
          options: options,
          cancelOn: cancelOn,
          clock: clock,
          tracer: tracer,
        );
      } on AdbException catch (e) {
        final retry = switch (e) {
          AdbUnreachableException() ||
          AdbRefusedException() ||
          AdbClosedException() ||
          AdbTimeoutException() ||
          AdbProtocolException() => true,
          _ => false,
        };
        if (e is AdbCancelledException) {
          throw const AdbCancelledException(
            'Waiting for the device was cancelled',
          );
        }
        if (!retry || clock.elapsed >= deadline) rethrow;
        tracer?.call(
          AdbNoteTrace(at: clock.elapsed, message: 'waitFor: ${e.message}'),
        );
      }
      final left = deadline - clock.elapsed;
      final wait = delay < left ? delay : left;
      final current = pause = Completer<void>();
      final timer = clock.timer(wait, () {
        if (!current.isCompleted) current.complete();
      });
      await current.future;
      timer.cancel();
      pause = null;
      delay *= 2;
      if (delay > const Duration(seconds: 2)) {
        delay = const Duration(seconds: 2);
      }
    }
  }

  static Future<AdbConnection> _attempt(
    Object host,
    int port, {
    required List<AdbKeyPair> keys,
    required int tlsKey,
    required AdbConnectOptions options,
    required void Function()? onWaitingForApproval,
    required Future<void>? cancelOn,
    required AdbClock clock,
    required AdbTracer? tracer,
  }) async {
    final transport = await TcpTransport.connect(
      host,
      port,
      timeout: options.connectTimeout,
      cancelOn: cancelOn,
    );
    final link = MessageLink(transport, clock: clock, tracer: tracer)..start();
    var connected = false;
    void cancel() {
      if (!connected) {
        link.fail(
          const AdbCancelledException('The connection attempt was cancelled'),
        );
      }
    }

    cancelOn?.then((_) => cancel(), onError: (Object _) => cancel()).ignore();
    try {
      final result = await Handshake(
        link,
        keys: keys,
        options: options,
        onWaitingForApproval: onWaitingForApproval,
        tlsKey: tlsKey,
      ).run();
      if (link.failure case final failure?) throw failure;
      connected = true;
      return _PacketConnection(link, result, options);
    } on TlsKeyRejected {
      link.fail(
        const AdbUnauthorizedException('The key was not accepted over TLS'),
      );
      // A cancel that raced the rejection wins.
      if (link.failure case final AdbCancelledException failure) throw failure;
      rethrow;
    } on Object catch (e) {
      link.fail(
        e is AdbException
            ? e
            : AdbCancelledException('The handshake was abandoned', cause: e),
      );
      // The link's own failure (a cancel, a lost socket) explains more than
      // the handshake's view of it.
      if (link.failure case final AdbCancelledException failure
          when e is AdbException && e is! AdbCancelledException) {
        throw failure;
      }
      rethrow;
    }
  }

  /// The clock deadlines run on.
  AdbClock get clock;

  /// What the device said about itself: state, product, model, features.
  AdbBanner get device;

  /// The key the device accepted, or null if it asked for none (or the
  /// connection goes through an adb server).
  AdbKeyPair? get acceptedKey;

  /// The negotiated protocol version.
  int get protocolVersion;

  /// Whether the connection runs over TLS (a wireless debugging port).
  bool get isTls;

  /// The device's TLS certificate (DER) on a TLS connection, else null.
  /// adb has nothing to verify it against; an app can remember it (or its
  /// public key) after the first connection and compare it later.
  Uint8List? get deviceCertificate;

  /// The largest payload either side sends in one message.
  int get maxPayload;

  /// Whether delayed acknowledgements are in use on this connection.
  bool get delayedAck;

  /// Whether the device lists [feature] (it is used only if this library
  /// announced it too).
  bool supports(AdbFeature feature) => device.supports(feature);

  /// Whether the connection has ended.
  bool get isClosed;

  /// Why the connection ended, or null while it is open.
  AdbException? get closeReason;

  /// Completes when the connection has ended, for any reason. Never fails;
  /// see [closeReason].
  Future<void> get done;

  /// The options it was made with.
  @internal
  AdbConnectOptions get options;

  /// Shell commands.
  late final AdbShell shell = AdbShell(this);

  /// Apps: install, install several APKs or apps, uninstall.
  late final AdbPackages packages = AdbPackages(
    this,
    stallTimeout: options.transferStallTimeout,
    answerTimeout: options.packageManagerTimeout,
  );

  /// adbd's own services: root, unroot, remount, reboot, tcpip, usb,
  /// verity.
  late final AdbDaemon daemon = AdbDaemon(this);

  /// Debugging: JDWP, process tracking, logcat, screenshots, bug reports.
  late final AdbDebug debug = AdbDebug(this);

  /// `adb backup` and `adb restore`.
  late final AdbBackup backup = AdbBackup(this);

  /// Recovery: `adb sideload`.
  late final AdbRecovery recovery = AdbRecovery(this);

  /// Reverse forwarding: connections made on the device arrive here.
  late final AdbReverse reverse = AdbReverse(this);

  /// Forwards a local TCP port to [remote] on the device (`tcp:8080`,
  /// `localabstract:<name>`, `jdwp:<pid>`, …), like `adb forward`. [port]
  /// 0 picks a free port ([AdbForward.port] tells which). The forward ends
  /// with [AdbForward.close] or with this connection.
  Future<AdbForward> forward(
    String remote, {
    int port = 0,
    Object address = '127.0.0.1',
  }) => AdbForward.start(this, remote, port: port, address: address);

  /// Files: stat, list, read and write over the sync protocol.
  late final AdbSync sync = AdbSync(
    this,
    stallTimeout: options.transferStallTimeout,
  );

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
  AdbStream openStream(String service);

  /// Closes the connection. Open streams end; their pending calls fail with
  /// [AdbCancelledException].
  ///
  /// With [drain] (the default) bytes already written are sent first, for
  /// up to [AdbConnectOptions.acknowledgementTimeout]; without it the socket
  /// closes at once, which is what to do when the device may be gone.
  Future<void> close({bool drain = true});

  /// Accepts device-initiated `OPEN`s of [label] from now on.
  @internal
  void registerReverseTarget(
    String label,
    FutureOr<void> Function(AdbStream) handler,
  );

  /// Stops accepting them.
  @internal
  void unregisterReverseTarget(String label);

  @override
  String toString() =>
      'AdbConnection(${device.model ?? device.systemType}'
      "${isClosed ? ', closed' : ''})";
}

/// A connection that speaks the ADB protocol itself, over TCP or TLS.
final class _PacketConnection extends AdbConnection {
  _PacketConnection(this._link, this._handshake, this._options)
    : clock = _link.clock,
      super.base() {
    _core = _ConnectionCore(this);
    _lastInbound = clock.elapsed;
    _link.route(_core);
    _scheduleLivenessCheck();
  }

  final MessageLink _link;
  final HandshakeResult _handshake;
  final AdbConnectOptions _options;

  @override
  AdbConnectOptions get options => _options;
  late final _ConnectionCore _core;
  final Map<int, StreamEndpoint> _endpoints = {};
  final Completer<void> _done = Completer<void>();
  int _nextLocalId = 1;
  AdbException? _closeReason;
  Duration _lastInbound = Duration.zero;
  StreamEndpoint? _livenessProbe;
  Timer? _livenessTimer;

  /// The clock deadlines run on.
  @override
  final AdbClock clock;

  /// What the device said about itself: state, product, model, features.
  @override
  AdbBanner get device => _handshake.banner;

  /// The key the device accepted, or null if it asked for none.
  @override
  AdbKeyPair? get acceptedKey => _handshake.key;

  /// The negotiated protocol version.
  @override
  int get protocolVersion => _handshake.protocolVersion;

  /// Whether the connection runs over TLS (a wireless debugging port).
  @override
  bool get isTls => _handshake.tls;

  /// The device's TLS certificate (DER) on a TLS connection, else null.
  /// adb has nothing to verify it against; an app can remember it (or its
  /// public key) after the first connection and compare it later.
  @override
  Uint8List? get deviceCertificate => _handshake.deviceCertificate;

  /// The largest payload either side sends in one message.
  @override
  int get maxPayload => _handshake.maxPayload;

  /// Whether delayed acknowledgements are in use on this connection.
  @override
  bool get delayedAck => _handshake.delayedAck;

  /// Whether the connection has ended.
  @override
  bool get isClosed => _closeReason != null;

  /// Why the connection ended, or null while it is open.
  @override
  AdbException? get closeReason => _closeReason;

  /// Completes when the connection has ended, for any reason. Never fails;
  /// see [closeReason].
  @override
  Future<void> get done => _done.future;

  /// Like [open], but returns the stream at once, before the device
  /// answered; [AdbStream.opened] tells how the open went. Writes made
  /// before then wait.
  @override
  AdbStream openStream(String service) => AdbStream(_openEndpoint(service));

  /// Closes the connection. Open streams end; their pending calls fail with
  /// [AdbCancelledException].
  ///
  /// With [drain] (the default) bytes already written are sent first, for
  /// up to [AdbConnectOptions.acknowledgementTimeout]; without it the socket
  /// closes at once, which is what to do when the device may be gone.
  @override
  Future<void> close({bool drain = true}) async {
    if (_closeReason == null) {
      await _link.close(
        const AdbCancelledException('The connection was closed by the caller'),
        drainTimeout: drain ? _options.acknowledgementTimeout : Duration.zero,
      );
    }
    return done;
  }

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
        // The device opens a stream to us only for reverse forwarding, and
        // only to a target registered here; anything else is refused (adb
        // aborts on it, as an unchecked OPEN would let a device reach
        // whatever the host can).
        if (message.arg0 == 0) return;
        var target = utf8.decode(message.payload, allowMalformed: true);
        while (target.endsWith('\u0000')) {
          target = target.substring(0, target.length - 1);
        }
        final handler = _reverseTargets[target];
        // As adbd: the window must be there exactly when delayed
        // acknowledgements are on. And a device may not flood us.
        final reverseStreams = _endpoints.values.where((e) => e.accepted);
        if (handler == null ||
            delayedAck != (message.arg1 != 0) ||
            reverseStreams.length >= maxReverseStreams) {
          _link
            ..note('Refused a device-initiated OPEN of "$target"')
            ..send(AdbMessage.close(localId: 0, remoteId: message.arg0));
          return;
        }
        _acceptReverse(message, target, handler);
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

  /// The most device-initiated streams open at once; more are refused.
  static const int maxReverseStreams = 256;

  /// Reverse targets: our label → what handles a device connection.
  final Map<String, FutureOr<void> Function(AdbStream)> _reverseTargets = {};

  /// Accepts device-initiated `OPEN`s of [label] from now on.
  @internal
  @override
  void registerReverseTarget(
    String label,
    FutureOr<void> Function(AdbStream) handler,
  ) => _reverseTargets[label] = handler;

  /// Stops accepting them.
  @internal
  @override
  void unregisterReverseTarget(String label) => _reverseTargets.remove(label);

  void _acceptReverse(
    AdbMessage open,
    String target,
    FutureOr<void> Function(AdbStream) handler,
  ) {
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
      ..send(
        AdbMessage.okay(
          localId: endpoint.localId,
          remoteId: open.arg0,
          // With delayed acknowledgements our OKAY announces our window.
          acknowledged: delayedAck ? _options.receiveWindow : null,
        ),
      );
    final stream = AdbStream(endpoint);
    Future.sync(() => handler(stream))
        .then<void>(
          (_) {},
          onError: (Object e) {
            _link.note('A reverse handler for "$target" failed: $e');
            unawaited(stream.close());
          },
        )
        .ignore();
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

  final _PacketConnection _connection;

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
