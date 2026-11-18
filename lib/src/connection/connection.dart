// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../services/backup.dart';
import '../services/daemon.dart';
import '../services/debug.dart';
import '../services/forward.dart';
import '../services/packages.dart';
import '../services/properties.dart';
import '../services/recovery.dart';
import '../services/reverse.dart';
import '../services/shell.dart';
import '../services/sync.dart';
import '../stream/adb_stream.dart';
import '../trace.dart';
import '../transport/tcp_transport.dart';
import '../transport/transport.dart';
import 'handshake.dart';
import 'message_link.dart';
import 'options.dart';
import 'packet_connection.dart';

/// A connection to adbd on a device.
///
/// Open one with [connect]; then open streams to services with [open], or use the service helpers such as [shell]. Many
/// streams can be open at once over one connection.
///
/// The connection ends when either side closes it or anything fails; every open stream and pending call then fails with
/// the same [closeReason].
abstract base class AdbConnection {
  /// For the implementations in this package (over ADB packets, and through an adb server); not meant to be extended
  /// elsewhere. Other links go through [connectTransport].
  @internal
  AdbConnection.base();

  /// Connects to adbd at [host]:[port] (5555 for classic network debugging) and authenticates with [key], then
  /// [extraKeys] in turn.
  ///
  /// When the device trusts none of them and [AdbConnectOptions.allowPrompt] is set (the default), [key]'s public key
  /// is offered and the device shows "Allow debugging?"; [onWaitingForApproval] is called then, and the call waits up
  /// to [AdbConnectOptions.approvalTimeout] for the user.
  ///
  /// When [cancelOn] completes before the connection is up (the user backed out of "Allow debugging?", say), the
  /// attempt stops at once, the socket is closed, and the call throws [AdbCancelledException].
  ///
  /// Throws [AdbUnreachableException], [AdbRefusedException], [AdbUnauthorizedException], [AdbTimeoutException],
  /// [AdbProtocolException], [AdbCancelledException], or [AdbNotSupportedException] for a TLS (wireless debugging)
  /// port; [ArgumentError] for invalid [options].
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
  }) => connectTransport(
    () => TcpTransport.connect(host, port, timeout: options.connectTimeout, cancelOn: cancelOn),
    key: key,
    extraKeys: extraKeys,
    options: options,
    onWaitingForApproval: onWaitingForApproval,
    cancelOn: cancelOn,
    clock: clock,
    tracer: tracer,
  );

  /// Like [connect], over a transport of your own: USB, a tunnel, a socket made elsewhere. [open] makes a fresh
  /// transport each time it is called (a TLS port needs one per key tried); it may throw [AdbException]s as [connect]
  /// does.
  static Future<AdbConnection> connectTransport(
    Future<AdbTransport> Function() open, {
    required AdbKeyPair key,
    List<AdbKeyPair> extraKeys = const [],
    AdbConnectOptions options = const AdbConnectOptions(),
    void Function()? onWaitingForApproval,
    Future<void>? cancelOn,
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    options.validate();
    final keys = [key, ...extraKeys];

    // Classic ports try every key in one handshake. A TLS port takes one key per TLS session, so a key the device does
    // not trust costs a new connection to try the next.
    for (var tlsKey = 0; ; tlsKey++) {
      final link = MessageLink(await open(), clock: clock, tracer: tracer)..start();
      try {
        return await _handshake(link, keys, tlsKey, options, onWaitingForApproval, cancelOn);
      } on TlsKeyRejected catch (e) {
        if (tlsKey < extraKeys.length) continue;
        throw AdbUnauthorizedException(
          'The device closed the TLS session before CNXN: most likely it does not trust the key '
          '(on a wireless debugging port, pair it first), or the connection dropped',
          cause: e.cause,
        );
      }
    }
  }

  /// Connects to a device that is coming back: after [AdbDaemon.reboot], [AdbDaemon.root], [AdbDaemon.tcpip] and the
  /// like, or a device that is still booting. Retries [connect] with a pause that grows from 250 ms to 2 s until it
  /// succeeds or [timeout] passes.
  ///
  /// Only "not there yet" failures are retried (unreachable, refused, closed, timeouts, a garbled exchange while adbd
  /// starts). A device that answers and refuses the key fails at once with [AdbUnauthorizedException]. On timeout the
  /// last failure is thrown; [cancelOn] stops waiting with [AdbCancelledException].
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
    const cancelled = AdbCancelledException('Waiting for the device was cancelled');
    const longestPause = Duration(seconds: 2);
    final deadline = clock.elapsed + timeout;
    var isCancelled = false;
    cancelOn?.whenComplete(() => isCancelled = true).ignore();

    var pause = const Duration(milliseconds: 250);
    while (true) {
      if (isCancelled) throw cancelled;
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
      } on AdbCancelledException {
        throw cancelled;
      } on AdbException catch (e) {
        final notThereYet =
            e is AdbUnreachableException ||
            e is AdbRefusedException ||
            e is AdbClosedException ||
            e is AdbTimeoutException ||
            e is AdbProtocolException;
        if (!notThereYet || clock.elapsed >= deadline) rethrow;
        tracer?.call(AdbNoteTrace(at: clock.elapsed, message: 'waitFor: ${e.message}'));
      }

      final left = deadline - clock.elapsed;
      await clock.sleep(pause < left ? pause : left, cancelOn: cancelOn);
      pause = pause * 2 < longestPause ? pause * 2 : longestPause;
    }
  }

  static Future<AdbConnection> _handshake(
    MessageLink link,
    List<AdbKeyPair> keys,
    int tlsKey,
    AdbConnectOptions options,
    void Function()? onWaitingForApproval,
    Future<void>? cancelOn,
  ) async {
    var connected = false;
    cancelOn?.whenComplete(() {
      if (!connected) link.fail(const AdbCancelledException('The connection attempt was cancelled'));
    }).ignore();

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
      return PacketConnection(link, result, options);
    } on Object catch (e) {
      link.fail(switch (e) {
        TlsKeyRejected() => const AdbUnauthorizedException('The key was not accepted over TLS'),
        AdbException() => e,
        _ => AdbCancelledException('The handshake was abandoned', cause: e),
      });
      // A cancel that raced the failure wins: the link's own reason explains more than the handshake's view of it.
      if (link.failure case final AdbCancelledException failure when e is TlsKeyRejected || e is AdbException) {
        throw failure;
      }
      rethrow;
    }
  }

  /// The clock deadlines run on.
  AdbClock get clock;

  /// What the device said about itself: state, product, model, features.
  AdbBanner get device;

  /// The key the device accepted, or null if it asked for none (or the connection goes through an adb server).
  AdbKeyPair? get acceptedKey;

  /// The negotiated protocol version.
  int get protocolVersion;

  /// Whether the connection runs over TLS (a wireless debugging port).
  bool get isTls;

  /// The device's TLS certificate (DER) on a TLS connection, else null. adb has nothing to verify it against; an app
  /// can remember it (or its public key) after the first connection and compare it later.
  Uint8List? get deviceCertificate;

  /// The largest payload either side sends in one message.
  int get maxPayload;

  /// Whether delayed acknowledgements are in use on this connection.
  bool get delayedAck;

  /// Whether the device lists [feature] (it is used only if this library announced it too).
  bool supports(AdbFeature feature) => device.supports(feature);

  /// Whether the connection has ended.
  bool get isClosed;

  /// Why the connection ended, or null while it is open.
  AdbException? get closeReason;

  /// Completes when the connection has ended, for any reason. Never fails; see [closeReason].
  Future<void> get done;

  /// The options it was made with.
  @internal
  AdbConnectOptions get options;

  /// Shell commands.
  late final AdbShell shell = AdbShell(this);

  /// System properties: `getprop`, `setprop`, the serial number, the API level.
  late final AdbProperties properties = AdbProperties(this);

  /// Apps: install, install several APKs or apps, uninstall, list, enable, disable, clear, permissions.
  late final AdbPackages packages = AdbPackages(
    this,
    stallTimeout: options.transferStallTimeout,
    answerTimeout: options.packageManagerTimeout,
  );

  /// adbd's own services: root, unroot, remount, reboot, tcpip, usb, verity.
  late final AdbDaemon daemon = AdbDaemon(this);

  /// Debugging: JDWP, process tracking, logcat, screenshots, bug reports.
  late final AdbDebug debug = AdbDebug(this);

  /// `adb backup` and `adb restore`.
  late final AdbBackup backup = AdbBackup(this);

  /// Recovery: `adb sideload`.
  late final AdbRecovery recovery = AdbRecovery(this);

  /// Reverse forwarding: connections made on the device arrive here.
  late final AdbReverse reverse = AdbReverse(this);

  /// Files: stat, list, read and write over the sync protocol.
  late final AdbSync sync = AdbSync(this, stallTimeout: options.transferStallTimeout);

  /// Forwards a local TCP port to [remote] on the device (`tcp:8080`, `localabstract:<name>`, `jdwp:<pid>`, …), like
  /// `adb forward`. [port] 0 picks a free port ([AdbForward.port] tells which). The forward ends with
  /// [AdbForward.close] or with this connection.
  Future<AdbForward> forward(String remote, {int port = 0, Object address = '127.0.0.1'}) =>
      AdbForward.start(this, remote, port: port, address: address);

  /// Opens a stream to [service] on the device, such as `shell:ls` or `sync:`.
  ///
  /// Completes when the device accepted it. Throws [AdbServiceUnavailableException] when the device refuses, and the
  /// connection's [closeReason] when it ends first.
  Future<AdbStream> open(String service) async {
    final stream = openStream(service);
    await stream.opened;
    return stream;
  }

  /// Like [open], but returns the stream at once, before the device answered; [AdbStream.opened] tells how the open
  /// went. Writes made before then wait.
  ///
  /// Throws [ArgumentError] for a name with a NUL, which would cut it short on the device; only `abb:` and `abb_exec:`
  /// use NULs, to separate their arguments.
  AdbStream openStream(String service);

  /// Throws [ArgumentError] when [service] cannot be sent as it is (see [openStream]).
  @internal
  static void checkServiceName(String service) {
    if (service.contains('\u0000') && !service.startsWith('abb:') && !service.startsWith('abb_exec:')) {
      throw ArgumentError.value(service, 'service', 'contains a NUL, which would end it on the device');
    }
  }

  /// Closes the connection. Open streams end; their pending calls fail with [AdbCancelledException].
  ///
  /// With [drain] (the default) bytes already written are sent first, for up to
  /// [AdbConnectOptions.acknowledgementTimeout]; without it the socket closes at once, which is what to do when the
  /// device may be gone.
  Future<void> close({bool drain = true});

  /// Accepts device-initiated `OPEN`s of [label] from now on.
  @internal
  void registerReverseTarget(String label, AdbReverseHandler handler);

  /// Stops accepting them.
  @internal
  void unregisterReverseTarget(String label);

  @override
  String toString() => "AdbConnection(${device.model ?? device.systemType}${isClosed ? ', closed' : ''})";
}
