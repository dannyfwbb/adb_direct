// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/crypto/spake2.dart';
import 'package:adb_direct/src/crypto/tls_exporter.dart';
import 'package:adb_direct/src/pairing/pairing_protocol.dart';

/// How the fake device behaves.
enum PairingServerMode {
  /// Pairs like adbd: answers with its GUID when the code matches.
  normal,

  /// Closes the session when the client's info does not decrypt, as adbd does with a wrong code (it never sends its own
  /// then).
  closeOnWrongCode,

  /// Sends a SPAKE2 message that is not a curve point.
  badPoint,

  /// Accepts TLS and says nothing.
  silent,
}

/// adbd's pairing server, built from the library's own pairing primitives in the server role. It proves the two roles
/// agree (symmetry), not that adbd does: the SPAKE2 vectors and the real device test cover that.
///
/// dart:io gives a TLS server no key log, so the exporter comes from the client's [keyLog] lines (the secret is the
/// same on both ends).
final class FakePairingServer {
  FakePairingServer._(this._server, this.code, this.guid, this.mode);

  /// Starts on a free port.
  static Future<FakePairingServer> start({
    required String code,
    required AdbKeyPair serverKey,
    String guid = 'adb-FAKE0001-AbCdEf',
    PairingServerMode mode = PairingServerMode.normal,
  }) async {
    final identity = serverKey.tlsIdentity(now: DateTime.now().toUtc());
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    final server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    final fake = FakePairingServer._(server, code, guid, mode);
    server.listen(fake._serve, onError: (Object _) {});
    return fake;
  }

  final SecureServerSocket _server;

  /// The code the device shows.
  final String code;

  /// The GUID it answers with.
  final String guid;

  /// Its behaviour.
  final PairingServerMode mode;

  /// Pass to `AdbPairing.pair(keyLog:)`.
  final List<String> keyLog = [];

  /// The public keys (adb text form) that paired.
  final List<String> pairedKeys = [];

  /// Failures seen on the device side.
  final List<Object> failures = [];

  /// The port.
  int get port => _server.port;

  /// Stops listening.
  Future<void> close() => _server.close();

  Future<void> _serve(SecureSocket socket) async {
    final reader = PairingReader(socket);
    try {
      if (mode == PairingServerMode.silent) {
        await Future<void>.delayed(const Duration(seconds: 30));
        return;
      }
      final exported = TlsExporter.fromKeyLog(keyLog).export(pairingExporterLabel, pairingExporterLength);
      if (mode == PairingServerMode.badPoint) {
        await reader.next();
        socket.add(pairingPacket(PairingPacket.spake2Message, Uint8List(32)..[0] = 2));
        await reader.next().catchError((Object _) => (0, Uint8List(0)));
        return;
      }
      final info = await _exchange(socket, reader, [...utf8.encode(code), ...exported]);
      final (type, key) = PeerInfo.parse(info);
      if (type == PeerInfo.rsaPublicKey) pairedKeys.add(key);
    } on Object catch (e) {
      failures.add(e);
    } finally {
      await reader.cancel();
      socket.destroy();
    }
  }

  Future<Uint8List> _exchange(SecureSocket socket, PairingReader reader, List<int> password) async {
    if (mode != PairingServerMode.closeOnWrongCode) {
      return runPairingExchange(
        role: Spake2Role.bob,
        password: password,
        myInfo: PeerInfo.build(PeerInfo.deviceGuid, utf8.encode(guid)),
        reader: reader,
        write: socket.add,
      );
    }
    // adbd's order on a wrong code: read the client's info first, fail to decrypt it, close without answering.
    final spake = Spake2(Spake2Role.bob, myName: pairingServerName, theirName: pairingClientName);
    socket.add(pairingPacket(PairingPacket.spake2Message, spake.generateMessage(password)));
    final (_, theirMessage) = await reader.next();
    final cipher = PairingCipher(spake.processMessage(theirMessage));
    final (_, sealed) = await reader.next();
    final info = cipher.decrypt(sealed);
    if (info == null) throw StateError('wrong code');
    socket.add(
      pairingPacket(PairingPacket.peerInfo, cipher.encrypt(PeerInfo.build(PeerInfo.deviceGuid, utf8.encode(guid)))),
    );
    return info;
  }
}
