// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../clock.dart';
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

/// Thrown by [Handshake.run] when the device closed the TLS session before `CNXN`: it does not trust the key presented,
/// and the caller may try the next key on a new connection.
final class TlsKeyRejected implements Exception {
  /// Creates the signal; [cause] is how the session ended.
  const TlsKeyRejected(this.cause);

  /// The close or error seen. A dropped network looks the same from here, so callers keep it for the final error.
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
/// A device without authentication answers `CNXN` with `CNXN`. A device on a wireless-debugging port answers with
/// `STLS`:
///
/// ```
/// < STLS                   > STLS, then TLS 1.3 with the key's certificate
/// < CNXN(…) inside TLS     (no AUTH: the certificate is the authentication)
/// ```
///
/// One TLS handshake presents one key ([tlsKey]); a device that does not trust it closes the session, and [run] throws
/// [TlsKeyRejected].
final class Handshake {
  /// Prepares a handshake over [link] trying [keys] in order.
  Handshake(this.link, {required this.keys, required this.options, this.onWaitingForApproval, this.tlsKey = 0});

  /// The link, started and not yet routed.
  final MessageLink link;

  /// Keys to try, in order. The first one is offered to the user when none is trusted and prompting is allowed.
  final List<AdbKeyPair> keys;

  /// The index in [keys] of the key to present if the device asks for TLS.
  final int tlsKey;

  /// Timeouts and features.
  final AdbConnectOptions options;

  /// Called when the public key has been offered and the device is showing "Allow debugging?".
  final void Function()? onWaitingForApproval;

  int _signedWith = 0;
  bool _offered = false;
  AdbKeyPair? _accepted;
  bool _tls = false;
  Uint8List? _deviceCertificate;

  // One deadline per phase (before the offer, then the user's answer): messages that do not move the handshake on
  // cannot extend it.
  Duration _deadline = Duration.zero;

  Duration get _left {
    final left = _deadline - link.clock.elapsed;
    return left > Duration.zero ? left : Duration.zero;
  }

  /// Runs the handshake. Throws an [AdbException] when it fails; the caller closes the link then.
  Future<HandshakeResult> run() async {
    final cnxn = AdbMessage.connect(banner: AdbBanner.host(options.hostFeatures).encode());
    if (cnxn.payload.length > AdbProtocol.maxPayloadV1) {
      throw ArgumentError('Host banner exceeds ${AdbProtocol.maxPayloadV1} B');
    }
    link
      ..withChecksum = true
      ..note('Handshake: sending CNXN')
      ..send(cnxn);
    _deadline = link.clock.elapsed + options.handshakeTimeout;

    while (true) {
      final message = await _next();
      switch (message.command) {
        case AdbCommand.connect:
          return _connected(message);
        case AdbCommand.stls:
          await _startTls();
        case AdbCommand.auth:
          _answerToken(message);
        case AdbCommand.open || AdbCommand.okay || AdbCommand.close || AdbCommand.write || AdbCommand.sync:
          // Messages before CNXN must be ignored (protocol.md).
          link.note('Handshake: ignored ${message.command.wireName}');
      }
    }
  }

  Future<AdbMessage> _next() async {
    try {
      return await link.next(
        timeout: _left,
        onTimeout: () => _offered
            ? AdbUnauthorizedException('The device did not accept the key within ${options.approvalTimeout}')
            : AdbTimeoutException('The device did not answer the handshake within ${options.handshakeTimeout}'),
      );
    } on AdbClosedException catch (e) {
      // After TLS the device closes a session whose key it does not trust (TLS 1.3 completes on our side before it
      // decides).
      if (_tls) throw TlsKeyRejected(e);
      rethrow;
    }
  }

  Future<void> _startTls() async {
    if (_tls || _signedWith > 0 || _offered) throw const AdbProtocolException('STLS out of order');
    if (tlsKey >= keys.length) {
      throw const AdbUnauthorizedException('The device wants TLS and there is no key to present');
    }

    final key = keys[tlsKey];
    link
      ..note('Handshake: STLS; TLS with key ${tlsKey + 1}')
      ..send(AdbMessage.stls());
    final identity = key.tls(options.now);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    final timeout = _left;
    final certificate = await link.clock.deadline(
      link.startTls(context: context),
      timeout,
      () => AdbTimeoutException('The TLS handshake did not finish within $timeout'),
    );

    _tls = true;
    _accepted = key;
    _deviceCertificate = certificate?.der;
    link.note('Handshake: TLS up; waiting for CNXN');
    _deadline = link.clock.elapsed + options.handshakeTimeout;
  }

  void _answerToken(AdbMessage auth) {
    if (auth.arg0 != AdbAuthType.token.value) {
      throw AdbProtocolException('Unexpected AUTH type ${auth.arg0} from the device');
    }
    if (auth.payload.length != AdbProtocol.authTokenLength) {
      throw AdbProtocolException('AUTH token of ${auth.payload.length} bytes');
    }
    if (_tls) throw const AdbProtocolException('AUTH after TLS');
    if (_offered) throw const AdbUnauthorizedException('The device refused the key');

    if (_signedWith < keys.length) {
      final key = _accepted = keys[_signedWith++];
      link
        ..note('Handshake: signing the token with key $_signedWith')
        ..send(AdbMessage.auth(AdbAuthType.signature, key.signAuthToken(auth.payload)));
    } else if (options.allowPrompt && keys.isNotEmpty) {
      _offered = true;
      _accepted = keys.first;
      _deadline = link.clock.elapsed + options.approvalTimeout;
      link
        ..note('Handshake: offering the public key; waiting for the user')
        ..send(AdbMessage.auth(AdbAuthType.rsaPublicKey, [...utf8.encode(keys.first.publicKey.encode()), 0]));
      onWaitingForApproval?.call();
    } else {
      throw const AdbUnauthorizedException('The device does not trust the key');
    }
  }

  HandshakeResult _connected(AdbMessage cnxn) {
    final version = cnxn.arg0 < AdbProtocol.version ? cnxn.arg0 : AdbProtocol.version;
    if (version < AdbProtocol.versionMin) {
      throw AdbProtocolException('Unsupported protocol version 0x${cnxn.arg0.toRadixString(16)}');
    }
    if (cnxn.arg1 == 0) throw const AdbProtocolException('The device announced maxdata 0');

    final maxPayload = cnxn.arg1 < AdbProtocol.maxPayload ? cnxn.arg1 : AdbProtocol.maxPayload;
    final banner = AdbBanner.parse(cnxn.payload);
    final delayedAck = options.hostFeatures.contains(AdbFeature.delayedAck) && banner.supports(AdbFeature.delayedAck);
    link
      ..withChecksum = version < AdbProtocol.versionSkipChecksum
      ..maxIncomingPayload = maxPayload
      ..note('Handshake: online, version 0x${version.toRadixString(16)}, maxdata $maxPayload, delayed ACK $delayedAck');
    return HandshakeResult(
      banner: banner,
      protocolVersion: version,
      maxPayload: maxPayload,
      delayedAck: delayedAck,
      key: _accepted,
      tls: _tls,
      deviceCertificate: _deviceCertificate,
    );
  }
}
