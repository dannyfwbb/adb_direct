// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart' show AdbConnection;
import '../crypto/adb_key_pair.dart';
import '../crypto/spake2.dart';
import '../crypto/tls_exporter.dart';
import '../errors.dart';
import '../transport/tcp_transport.dart';
import 'pairing_protocol.dart';

/// A device that paired.
@immutable
final class AdbPairedDevice {
  /// Creates the result.
  const AdbPairedDevice({required this.guid, required this.certificate});

  /// The device's wireless debugging GUID (`adb-<serial>-<random>`): the instance name it announces on mDNS, so the
  /// paired device can be found again on `_adb-tls-connect._tcp`.
  final String guid;

  /// The certificate (DER) the device presented on the pairing port.
  final Uint8List certificate;
}

/// Pairing with Android 11+ wireless debugging: puts a key into the device's trusted keys with the code it shows,
/// without a cable or a prompt.
abstract final class AdbPairing {
  /// Pairs [key] with the device at [host]:[port], the pairing port (not the connection port) from "Pair device with
  /// pairing code", using the six-digit [code] on its screen (or the password of a QR code).
  ///
  /// Afterwards [AdbConnection.connect] to the device's wireless debugging port with [key] works without a prompt. The
  /// key's comment (`user@host`) is what the device lists under paired devices.
  ///
  /// Throws [AdbPairingException] (with [AdbPairingFailure.wrongCode] for a code the device rejects),
  /// [AdbUnreachableException], [AdbRefusedException] (no pairing server: the dialog was closed), [AdbTimeoutException]
  /// after [timeout], or [AdbCancelledException] when [cancelOn] completes first.
  ///
  /// [keyLog] receives the TLS session's key-log lines (NSS format), for decrypting a capture in Wireshark; they are
  /// secrets.
  static Future<AdbPairedDevice> pair(
    Object host,
    int port, {
    required String code,
    required AdbKeyPair key,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration timeout = const Duration(seconds: 30),
    Future<void>? cancelOn,
    void Function(String line)? keyLog,
    AdbClock clock = AdbClock.system,
  }) async {
    if (code.isEmpty) throw ArgumentError.value(code, 'code', 'is empty');
    final publicKey = utf8.encode(key.publicKey.encode());
    final myInfo = PeerInfo.build(PeerInfo.rsaPublicKey, publicKey);

    final lines = <String>[];
    final identity = key.tls;
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));

    var cancelled = false;
    SecureSocket? socket;
    ConnectionTask<SecureSocket>? task;
    void stop() {
      cancelled = true;
      task?.cancel();
      socket?.destroy();
    }

    cancelOn?.then((_) => stop(), onError: (Object _) => stop()).ignore();
    var timedOut = false;
    final deadline = clock.timer(timeout, () {
      timedOut = true;
      stop();
    });
    AdbException interrupted() => timedOut
        ? AdbTimeoutException('Pairing did not finish within $timeout')
        : const AdbCancelledException('Pairing was cancelled');

    try {
      try {
        task = await SecureSocket.startConnect(
          host,
          port,
          context: context,
          // Neither side checks the other's certificate: the code, bound to this TLS session by the exporter, is what
          // authenticates.
          onBadCertificate: (_) => true,
          keyLog: (line) {
            lines.add(line);
            keyLog?.call(line);
          },
        );
        if (cancelled) task.cancel();
        socket = await task.socket.timeout(
          connectTimeout,
          onTimeout: () {
            task?.cancel();
            throw const SocketException('Connection timed out');
          },
        );
      } on SocketException catch (e) {
        if (cancelled) throw interrupted();
        throw TcpTransport.mapConnectError(e, '$host:$port');
      } on HandshakeException catch (e) {
        if (cancelled) throw interrupted();
        throw AdbPairingException('The TLS handshake on the pairing port failed', cause: e);
      }
      if (cancelled) throw interrupted();

      final open = socket;
      // Write failures surface here too; the reader reports the loss.
      open.done.ignore();
      final Uint8List exported;
      try {
        exported = await _exporter(lines);
      } on FormatException catch (e) {
        throw AdbNotSupportedException('This platform does not expose the TLS secrets pairing needs', cause: e);
      }
      final reader = PairingReader(open);
      try {
        final info = await runPairingExchange(
          role: Spake2Role.alice,
          password: [...utf8.encode(code), ...exported],
          myInfo: myInfo,
          reader: reader,
          write: open.add,
        );
        final (type, guid) = PeerInfo.parse(info);
        if (type != PeerInfo.deviceGuid) throw AdbPairingException('The device sent peer info of type $type');
        return AdbPairedDevice(guid: guid, certificate: open.peerCertificate?.der ?? Uint8List(0));
      } on AdbException {
        if (cancelled) throw interrupted();
        rethrow;
      } finally {
        await reader.cancel();
      }
    } finally {
      deadline.cancel();
      socket?.destroy();
    }
  }

  /// The exported keying material. dart:io delivers key-log lines through the event queue; if they are not there yet
  /// when the handshake completes, give them one turn.
  static Future<Uint8List> _exporter(List<String> lines) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return TlsExporter.fromKeyLog(lines).export(pairingExporterLabel, pairingExporterLength);
      } on FormatException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}
