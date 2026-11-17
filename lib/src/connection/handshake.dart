// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

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
/// a wireless-debugging port answers with `STLS`, which needs TLS.
final class Handshake {
  /// Prepares a handshake over [link] trying [keys] in order.
  Handshake(
    this.link, {
    required this.keys,
    required this.options,
    this.onWaitingForApproval,
  });

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
      ..send(
        AdbMessage(
          AdbCommand.connect,
          AdbProtocol.version,
          AdbProtocol.maxPayload,
          bannerBytes,
        ),
      );

    var nextKey = 0;
    var offered = false;
    AdbKeyPair? accepted;
    // One deadline per phase (before the offer, then the user's answer):
    // messages that do not move the handshake on cannot extend it.
    var deadline = link.clock.elapsed + options.handshakeTimeout;
    while (true) {
      final left = deadline - link.clock.elapsed;
      final message = await link.next(
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
      switch (message.command) {
        case AdbCommand.connect:
          return _connected(message, accepted ?? (offered ? keys.first : null));
        case AdbCommand.stls:
          throw const AdbNotSupportedException(
            'The device asks for TLS (a wireless debugging port); TLS '
            'connections are not supported yet',
          );
        case AdbCommand.auth:
          if (message.arg0 != AdbAuthType.token.value) {
            throw AdbProtocolException(
              'Unexpected AUTH type ${message.arg0} from the device',
            );
          }
          if (message.payload.length != AdbProtocol.authTokenLength) {
            throw AdbProtocolException(
              'AUTH token of ${message.payload.length} bytes',
            );
          }
          if (offered) {
            throw const AdbUnauthorizedException('The device refused the key');
          }
          if (nextKey < keys.length) {
            final key = keys[nextKey++];
            accepted = key;
            link
              ..note('Handshake: signing the token with key $nextKey')
              ..send(
                AdbMessage.auth(
                  AdbAuthType.signature,
                  key.signAuthToken(message.payload),
                ),
              );
          } else if (options.allowPrompt && keys.isNotEmpty) {
            offered = true;
            accepted = null;
            deadline = link.clock.elapsed + options.approvalTimeout;
            link
              ..note('Handshake: offering the public key; waiting for the user')
              ..send(
                AdbMessage.auth(AdbAuthType.rsaPublicKey, [
                  ...utf8.encode(keys.first.publicKey.encode()),
                  0,
                ]),
              );
            onWaitingForApproval?.call();
          } else {
            throw const AdbUnauthorizedException(
              'The device does not trust the key',
            );
          }
        case AdbCommand.open ||
            AdbCommand.okay ||
            AdbCommand.close ||
            AdbCommand.write ||
            AdbCommand.sync:
          // Messages before CNXN must be ignored (protocol.md).
          link.note('Handshake: ignored ${message.command.wireName}');
      }
    }
  }

  HandshakeResult _connected(AdbMessage cnxn, AdbKeyPair? key) {
    final version = cnxn.arg0 < AdbProtocol.version
        ? cnxn.arg0
        : AdbProtocol.version;
    if (version < AdbProtocol.versionMin) {
      throw AdbProtocolException(
        'Unsupported protocol version 0x${cnxn.arg0.toRadixString(16)}',
      );
    }
    if (cnxn.arg1 == 0) {
      throw const AdbProtocolException('The device announced maxdata 0');
    }
    final maxPayload = cnxn.arg1 < AdbProtocol.maxPayload
        ? cnxn.arg1
        : AdbProtocol.maxPayload;
    final banner = AdbBanner.parse(cnxn.payload);
    final delayedAck =
        options.hostFeatures.contains(AdbFeature.delayedAck) &&
        banner.supports(AdbFeature.delayedAck);
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
    );
  }
}
