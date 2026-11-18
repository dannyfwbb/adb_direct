// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/handshake.dart';
import '../connection/message_link.dart';
import '../connection/options.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/constants.dart';
import '../protocol/message.dart';
import '../trace.dart';
import '../transport/tcp_transport.dart';

/// What answered on a port.
enum AdbEndpointKind {
  /// adbd asking for authentication (`AUTH`): classic network debugging.
  adbAuthentication,

  /// adbd that needs no authentication (`CNXN` at once; userdebug builds,
  /// emulators).
  adbOpen,

  /// adbd asking for TLS (`STLS`): a wireless debugging connect port.
  adbTls,

  /// Something that is not adbd: it closed, stayed silent, or sent
  /// something else.
  notAdb,
}

/// The result of [AdbProbe.identify].
final class AdbEndpoint {
  /// Creates a result.
  const AdbEndpoint(this.kind, {this.banner});

  /// What answered.
  final AdbEndpointKind kind;

  /// The device's banner, when it answered with `CNXN`.
  final AdbBanner? banner;

  /// Whether adbd answered.
  bool get isAdb => kind != AdbEndpointKind.notAdb;

  @override
  String toString() => 'AdbEndpoint(${kind.name})';
}

/// Questions to a device that never make it ask its user anything.
///
/// Neither probe sends a public key, so no "Allow debugging?" appears on any
/// screen: safe for scanning a network full of other people's TVs.
abstract final class AdbProbe {
  /// Tells whether adbd answers at [host]:[port], and how: sends one
  /// `CNXN` and reads one message header.
  ///
  /// Throws [AdbUnreachableException] or [AdbRefusedException] when no
  /// connection can be made; returns [AdbEndpointKind.notAdb] when something
  /// else answers or nothing does within [timeout].
  static Future<AdbEndpoint> identify(
    Object host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    final transport = await TcpTransport.connect(host, port, timeout: timeout);
    final link = MessageLink(transport, clock: clock, tracer: tracer)..start();
    try {
      link.send(
        AdbMessage(
          AdbCommand.connect,
          AdbProtocol.version,
          AdbProtocol.maxPayload,
          utf8.encode(AdbBanner.host(const {}).encode()),
        ),
      );
      final AdbMessage answer;
      try {
        answer = await link.next(timeout: timeout, onTimeout: () => const AdbTimeoutException('No answer'));
      } on AdbException {
        // Silence, a close, or bytes that are not ADB messages.
        return const AdbEndpoint(AdbEndpointKind.notAdb);
      }
      return switch (answer.command) {
        AdbCommand.auth => const AdbEndpoint(AdbEndpointKind.adbAuthentication),
        AdbCommand.connect => AdbEndpoint(AdbEndpointKind.adbOpen, banner: AdbBanner.parse(answer.payload)),
        AdbCommand.stls => const AdbEndpoint(AdbEndpointKind.adbTls),
        _ => const AdbEndpoint(AdbEndpointKind.notAdb),
      };
    } finally {
      link.fail(const AdbCancelledException('Probe finished'));
    }
  }

  /// Tells whether the device at [host]:[port] trusts [key], without
  /// offering it: signs the device's token and closes after the answer.
  ///
  /// Returns true when the device accepted the signature (or needs no
  /// authentication), false when it did not. Throws
  /// [AdbUnreachableException], [AdbRefusedException],
  /// [AdbTimeoutException], [AdbProtocolException], or
  /// [AdbNotSupportedException] on a TLS port.
  static Future<bool> knowsKey(
    Object host,
    int port,
    AdbKeyPair key, {
    Duration timeout = const Duration(seconds: 5),
    AdbClock clock = AdbClock.system,
    AdbTracer? tracer,
  }) async {
    final transport = await TcpTransport.connect(host, port, timeout: timeout);
    final link = MessageLink(transport, clock: clock, tracer: tracer)..start();
    try {
      await Handshake(
        link,
        keys: [key],
        options: AdbConnectOptions(handshakeTimeout: timeout, allowPrompt: false),
      ).run();
      return true;
    } on AdbUnauthorizedException {
      return false;
    } finally {
      link.fail(const AdbCancelledException('Probe finished'));
    }
  }

  /// Identifies many endpoints at once, for a scan: at most [concurrency]
  /// connections open together; [timeout] bounds the connect and then the
  /// answer, so a silent endpoint costs up to twice it. Pausing the
  /// subscription stops new probes; cancelling lets running ones finish
  /// their timeout and close. Emits a result for
  /// each target where adbd answered (any [AdbEndpointKind] but
  /// [AdbEndpointKind.notAdb]), in the order they answer; targets that
  /// refuse, time out or speak something else are left out.
  ///
  /// Like [identify] it never authenticates, so no device shows a prompt.
  /// Which targets to try (a subnet, a port list) is the caller's policy.
  static Stream<AdbScanResult> scan(
    Iterable<(Object host, int port)> targets, {
    int concurrency = 32,
    Duration timeout = const Duration(seconds: 1),
    AdbClock clock = AdbClock.system,
  }) {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
    }
    late final StreamController<AdbScanResult> controller;
    final pending = targets.iterator;
    var running = 0;
    var cancelled = false;

    var exhausted = false;
    void next() {
      while (!cancelled && !controller.isPaused && !exhausted && running < concurrency) {
        try {
          if (!pending.moveNext()) {
            exhausted = true;
            break;
          }
        } on Object catch (e, s) {
          // The caller's target list failed: report it, stop taking more.
          controller.addError(e, s);
          exhausted = true;
          break;
        }
        final (host, port) = pending.current;
        running++;
        identify(
          host,
          port,
          timeout: timeout,
          clock: clock,
        ).then<AdbEndpoint?>((e) => e, onError: (Object _) => null).then((endpoint) {
          running--;
          if (cancelled) return;
          if (endpoint != null && endpoint.isAdb) {
            controller.add(AdbScanResult(host, port, endpoint));
          }
          next();
        }).ignore();
      }
      if (exhausted && running == 0 && !cancelled && !controller.isClosed) {
        unawaited(controller.close());
      }
    }

    controller = StreamController<AdbScanResult>(onListen: next, onResume: next, onCancel: () => cancelled = true);
    return controller.stream;
  }
}

/// An endpoint a scan found speaking ADB.
@immutable
final class AdbScanResult {
  /// Creates one.
  const AdbScanResult(this.host, this.port, this.endpoint);

  /// The host tried.
  final Object host;

  /// The port tried.
  final int port;

  /// How it answered.
  final AdbEndpoint endpoint;

  @override
  String toString() => 'AdbScanResult($host:$port ${endpoint.kind.name})';
}
