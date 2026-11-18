// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/constants.dart';
import '../protocol/message.dart';
import 'message_link.dart';
import 'options.dart';

/// What both sides agreed on.
final class HandshakeResult {
  /// Creates the result.
  const HandshakeResult({
    required this.banner,
    required this.protocolVersion,
    required this.maxPayload,
    required this.delayedAck,
    required this.key,
    this.tls = false,
    this.deviceCertificate,
  });

  /// The device's banner.
  final AdbBanner banner;

  /// The negotiated protocol version.
  final int protocolVersion;

  /// The negotiated payload limit.
  final int maxPayload;

  /// Whether delayed acknowledgements are in use.
  final bool delayedAck;

  /// The key the device accepted, or null when it did not ask for one.
  final AdbKeyPair? key;

  /// Whether the connection runs over TLS (a wireless debugging port).
  final bool tls;

  /// The device's TLS certificate (DER), when [tls].
  final Uint8List? deviceCertificate;
}

/// Thrown by [Handshake.run] when the device closed the TLS session before
/// `CNXN`: it does not trust the key presented, and the caller may try the
/// next key on a new connection.
final class TlsKeyRejected implements Exception {
  /// Creates the signal; [cause] is how the session ended.
  const TlsKeyRejected(this.cause);

  /// The close or error seen. A dropped network looks the same from here,
  /// so callers keep it for the final error.
  final AdbException cause;
}

/// The classic `CNXN`/`AUTH` handshake.
///
/// ```
/// > CNXN(version, maxdata, "host::features=…")
/// < AUTH(TOKEN)            > AUTH(SIGNATURE) with each key in turn
/// < AUTH(TOKEN)            > AUTH(RSAPUBLICKEY) if allowed: the device asks
/// < CNXN(version, maxdata, "device::…")
/// ```
///
/// A device without authentication answers `CNXN` with `CNXN`. A device on
/// a wireless-debugging port answers with `STLS`:
///
/// ```
/// < STLS                   > STLS, then TLS 1.3 with the key's certificate
/// < CNXN(…) inside TLS     (no AUTH: the certificate is the authentication)
/// ```
///
/// One TLS handshake presents one key ([tlsKey]); a device that does not
/// trust it closes the session, and [run] throws [TlsKeyRejected].
final class Handshake {
  /// Prepares a handshake over [link] trying [keys] in order.
  Handshake(this.link, {required this.keys, required this.options, this.onWaitingForApproval, this.tlsKey = 0});

  /// The index in [keys] of the key to present if the device asks for TLS.
  final int tlsKey;

  /// The link, started and not yet routed.
  final MessageLink link;

  /// Keys to try, in order. The first one is offered to the user when none
  /// is trusted and prompting is allowed.
  final List<AdbKeyPair> keys;

  /// Timeouts and features.
  final AdbConnectOptions options;

  /// Called when the public key has been offered and the device is showing
  /// "Allow debugging?".
  final void Function()? onWaitingForApproval;

  /// Runs the handshake. Throws an [AdbException] when it fails; the caller
  /// closes the link then.
  Future<HandshakeResult> run() async {
    final banner = AdbBanner.host(options.hostFeatures).encode();
    final bannerBytes = utf8.encode(banner);
    if (bannerBytes.length > AdbProtocol.maxPayloadV1) {
      throw ArgumentError('Host banner exceeds ${AdbProtocol.maxPayloadV1} B');
    }
    link
      ..withChecksum = true
      ..note('Handshake: sending CNXN')
      ..send(AdbMessage(AdbCommand.connect, AdbProtocol.version, AdbProtocol.maxPayload, bannerBytes));

    var nextKey = 0;
    var offered = false;
    AdbKeyPair? accepted;
    var tls = false;
    Uint8List? deviceCertificate;
    // One deadline per phase (before the offer, then the user's answer):
    // messages that do not move the handshake on cannot extend it.
    var deadline = link.clock.elapsed + options.handshakeTimeout;
    while (true) {
      final left = deadline - link.clock.elapsed;
      final AdbMessage message;
      try {
        message = await link.next(
          timeout: left > Duration.zero ? left : Duration.zero,
          onTimeout: () => offered
              ? AdbUnauthorizedException(
                  'The device did not accept the key within '
                  '${options.approvalTimeout}',
                )
              : AdbTimeoutException(
                  'The device did not answer the handshake within '
                  '${options.handshakeTimeout}',
                ),
        );
      } on AdbClosedException catch (e) {
        // After TLS the device closes a session whose key it does not
        // trust (TLS 1.3 completes on our side before it decides).
        if (tls) throw TlsKeyRejected(e);
        rethrow;
      }
      switch (message.command) {
        case AdbCommand.connect:
          return _connected(
            message,
            accepted ?? (offered ? keys.first : null),
            tls: tls,
            deviceCertificate: deviceCertificate,
          );
        case AdbCommand.stls:
          if (tls || nextKey > 0 || offered) {
            throw const AdbProtocolException('STLS out of order');
          }
          if (tlsKey >= keys.length) {
            throw const AdbUnauthorizedException('The device wants TLS and there is no key to present');
          }
          final key = keys[tlsKey];
          link
            ..note('Handshake: STLS; TLS with key ${tlsKey + 1}')
            ..send(AdbMessage.stls());
          final identity = key.tls;
          final context = SecurityContext(withTrustedRoots: false)
            ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
            ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
          final left = deadline - link.clock.elapsed;
          final certificate = await _within(
            link.startTls(context: context),
            left > Duration.zero ? left : Duration.zero,
          );
          tls = true;
          accepted = key;
          deviceCertificate = certificate?.der;
          link.note('Handshake: TLS up; waiting for CNXN');
          deadline = link.clock.elapsed + options.handshakeTimeout;
        case AdbCommand.auth:
          if (message.arg0 != AdbAuthType.token.value) {
            throw AdbProtocolException('Unexpected AUTH type ${message.arg0} from the device');
          }
          if (message.payload.length != AdbProtocol.authTokenLength) {
            throw AdbProtocolException('AUTH token of ${message.payload.length} bytes');
          }
          if (tls) {
            throw const AdbProtocolException('AUTH after TLS');
          }
          if (offered) {
            throw const AdbUnauthorizedException('The device refused the key');
          }
          if (nextKey < keys.length) {
            final key = keys[nextKey++];
            accepted = key;
            link
              ..note('Handshake: signing the token with key $nextKey')
              ..send(AdbMessage.auth(AdbAuthType.signature, key.signAuthToken(message.payload)));
          } else if (options.allowPrompt && keys.isNotEmpty) {
            offered = true;
            accepted = null;
            deadline = link.clock.elapsed + options.approvalTimeout;
            link
              ..note('Handshake: offering the public key; waiting for the user')
              ..send(AdbMessage.auth(AdbAuthType.rsaPublicKey, [...utf8.encode(keys.first.publicKey.encode()), 0]));
            onWaitingForApproval?.call();
          } else {
            throw const AdbUnauthorizedException('The device does not trust the key');
          }
        case AdbCommand.open || AdbCommand.okay || AdbCommand.close || AdbCommand.write || AdbCommand.sync:
          // Messages before CNXN must be ignored (protocol.md).
          link.note('Handshake: ignored ${message.command.wireName}');
      }
    }
  }

  /// [future] or a timeout on the link's clock; the caller destroys the
  /// link on failure.
  Future<T> _within<T>(Future<T> future, Duration timeout) {
    final done = Completer<T>();
    final timer = link.clock.timer(timeout, () {
      if (!done.isCompleted) {
        done.completeError(AdbTimeoutException('The TLS handshake did not finish within $timeout'));
      }
    });
    future
        .then(
          (value) {
            timer.cancel();
            if (!done.isCompleted) done.complete(value);
          },
          onError: (Object e, StackTrace s) {
            timer.cancel();
            if (!done.isCompleted) done.completeError(e, s);
          },
        )
        .ignore();
    return done.future;
  }

  HandshakeResult _connected(
    AdbMessage cnxn,
    AdbKeyPair? key, {
    required bool tls,
    required Uint8List? deviceCertificate,
  }) {
    final version = cnxn.arg0 < AdbProtocol.version ? cnxn.arg0 : AdbProtocol.version;
    if (version < AdbProtocol.versionMin) {
      throw AdbProtocolException('Unsupported protocol version 0x${cnxn.arg0.toRadixString(16)}');
    }
    if (cnxn.arg1 == 0) {
      throw const AdbProtocolException('The device announced maxdata 0');
    }
    final maxPayload = cnxn.arg1 < AdbProtocol.maxPayload ? cnxn.arg1 : AdbProtocol.maxPayload;
    final banner = AdbBanner.parse(cnxn.payload);
    final delayedAck = options.hostFeatures.contains(AdbFeature.delayedAck) && banner.supports(AdbFeature.delayedAck);
    link
      ..withChecksum = version < AdbProtocol.versionSkipChecksum
      ..maxIncomingPayload = maxPayload
      ..note(
        'Handshake: online, version 0x${version.toRadixString(16)}, '
        'maxdata $maxPayload, delayed ACK $delayedAck',
      );
    return HandshakeResult(
      banner: banner,
      protocolVersion: version,
      maxPayload: maxPayload,
      delayedAck: delayedAck,
      key: key,
      tls: tls,
      deviceCertificate: deviceCertificate,
    );
  }
}
