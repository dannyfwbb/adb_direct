// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/crypto/adb_key_pair.dart';
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';

/// adbd on a wireless debugging port, as far as the handshake goes:
///
/// ```
/// < CNXN (plain)      > STLS (plain)      < STLS (plain)
/// TLS 1.3, client certificate required: trusted keys only
/// > CNXN (inside TLS), then `echo:<text>` streams: OKAY, WRTE <text>, CLSE
/// ```
///
/// Like adbd it reads the plain messages byte-exactly, so the client's ClientHello stays in the socket for the TLS
/// layer. dart:io's server trusts certificates, not keys, so trusted keys are trusted through the certificate each
/// presents (`AdbKeyPair.tls`, made once per key). A rejected key sees what it sees from adbd: TLS completes on the
/// client, then the session closes before `CNXN`.
final class FakeTlsAdbd {
  FakeTlsAdbd._(this._server, this._context, this.certificateDer, this.banner);

  /// Starts a server trusting [trusted]; [speakTls] false answers STLS and then closes instead of starting TLS.
  static Future<FakeTlsAdbd> start({
    required List<AdbKeyPair> trusted,
    required AdbKeyPair serverKey,
    String banner = 'device::ro.product.model=TLS TV;features=shell_v2,cmd',
    bool speakTls = true,
    bool hangAfterStls = false,
  }) async {
    final identity = serverKey.tlsIdentity(now: DateTime.now().toUtc());
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    if (trusted.isNotEmpty) {
      context.setTrustedCertificatesBytes(utf8.encode(trusted.map((k) => k.tls(DateTime.now).certificatePem).join()));
    }
    final server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final adbd = FakeTlsAdbd._(server, context, identity.certificateDer, banner)
      .._speakTls = speakTls
      .._hang = hangAfterStls;
    server.listen(adbd._serve);
    return adbd;
  }

  final RawServerSocket _server;
  final SecurityContext _context;
  late final bool _speakTls;
  late final bool _hang;

  /// The server certificate (DER) the client should report.
  final Uint8List certificateDer;

  /// The banner sent in the TLS `CNXN`.
  final String banner;

  /// TCP connections accepted.
  int connections = 0;

  /// TLS sessions that ended in `CNXN`.
  int accepted = 0;

  /// TLS handshakes the server refused (untrusted certificate).
  int rejected = 0;

  /// The port to connect to.
  int get port => _server.port;

  /// Stops listening.
  Future<void> close() => _server.close();

  Future<void> _serve(RawSocket raw) async {
    connections++;
    final plain = _PlainReader(raw);
    try {
      final cnxn = await plain.message();
      if (cnxn.command != AdbCommand.connect) return raw.shutdown(SocketDirection.both);
      _write(raw, AdbMessage.stls(), withChecksum: true);
      final stls = await plain.message();
      if (stls.command != AdbCommand.stls) return raw.shutdown(SocketDirection.both);
      if (_hang) {
        // Never reads the ClientHello, never answers. Read events must be off: unread data re-raises them through
        // microtasks forever, starving every timer in this isolate.
        raw.readEventsEnabled = false;
        await Future<void>.delayed(const Duration(seconds: 10));
        await raw.close();
        return;
      }
      if (!_speakTls) {
        await raw.close();
        return;
      }
      final RawSecureSocket tls;
      try {
        tls = await RawSecureSocket.secureServer(
          raw,
          _context,
          subscription: plain.subscription,
          requestClientCertificate: true,
          requireClientCertificate: true,
        );
      } on Object {
        rejected++;
        await raw.close().catchError((Object _) => raw);
        return;
      }
      accepted++;
      _write(tls, AdbMessage(AdbCommand.connect, AdbProtocol.version, AdbProtocol.maxPayload, utf8.encode(banner)));
      _echo(tls);
    } on Object {
      await raw.close().catchError((Object _) => raw);
    }
  }

  void _echo(RawSecureSocket tls) {
    final reader = AdbMessageReader();
    final pending = <int, int>{}; // our id -> their id, awaiting their OKAY
    var nextId = 100;
    tls.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (tls.available() > 0) {
        final data = tls.read();
        if (data == null) break;
        reader.add(data);
      }
      for (final m in reader.drain()) {
        switch (m.command) {
          case AdbCommand.open:
            final service = utf8.decode(m.payload).replaceAll('\u0000', '');
            final id = nextId++;
            if (!service.startsWith('echo:')) {
              _write(tls, AdbMessage.close(localId: 0, remoteId: m.arg0));
              continue;
            }
            _write(tls, AdbMessage.okay(localId: id, remoteId: m.arg0));
            _write(tls, AdbMessage.write(localId: id, remoteId: m.arg0, data: utf8.encode(service.substring(5))));
            pending[id] = m.arg0;
          case AdbCommand.okay when pending.containsKey(m.arg1):
            _write(tls, AdbMessage.close(localId: m.arg1, remoteId: pending.remove(m.arg1)!));
          default:
        }
      }
    });
  }

  static void _write(RawSocket socket, AdbMessage m, {bool withChecksum = false}) {
    final bytes = AdbMessageCodec.encode(m, withChecksum: withChecksum);
    var offset = 0;
    while (offset < bytes.length) {
      offset += socket.write(bytes, offset);
    }
  }
}

/// Reads whole plain messages byte-exactly, as adbd does before TLS.
final class _PlainReader {
  _PlainReader(this._socket) {
    subscription = _socket.listen((event) {
      if (event == RawSocketEvent.read) _pump();
    });
  }

  final RawSocket _socket;

  /// Handed to the TLS layer, which cancels it with the socket.
  // ignore: cancel_subscriptions
  late final StreamSubscription<RawSocketEvent> subscription;
  final BytesBuilder _have = BytesBuilder();
  int _want = 0;
  Completer<Uint8List>? _waiting;

  Future<AdbMessage> message() async {
    final header = await _read(24);
    final length = ByteData.sublistView(header).getUint32(12, Endian.little);
    final payload = length == 0 ? Uint8List(0) : await _read(length);
    final reader = AdbMessageReader()
      ..add(header)
      ..add(payload);
    return reader.next()!;
  }

  Future<Uint8List> _read(int n) {
    _want = n;
    final waiting = _waiting = Completer<Uint8List>();
    _pump();
    return waiting.future;
  }

  void _pump() {
    final waiting = _waiting;
    if (waiting == null) return;
    while (_have.length < _want) {
      final data = _socket.read(_want - _have.length);
      if (data == null) return;
      _have.add(data);
    }
    _waiting = null;
    waiting.complete(_have.takeBytes());
  }
}
