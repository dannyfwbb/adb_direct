// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

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
        answer = await link.next(
          timeout: timeout,
          onTimeout: () => const AdbTimeoutException('No answer'),
        );
      } on AdbException {
        // Silence, a close, or bytes that are not ADB messages.
        return const AdbEndpoint(AdbEndpointKind.notAdb);
      }
      return switch (answer.command) {
        AdbCommand.auth => const AdbEndpoint(AdbEndpointKind.adbAuthentication),
        AdbCommand.connect => AdbEndpoint(
          AdbEndpointKind.adbOpen,
          banner: AdbBanner.parse(answer.payload),
        ),
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
        options: AdbConnectOptions(
          handshakeTimeout: timeout,
          allowPrompt: false,
        ),
      ).run();
      return true;
    } on AdbUnauthorizedException {
      return false;
    } finally {
      link.fail(const AdbCancelledException('Probe finished'));
    }
  }
}
