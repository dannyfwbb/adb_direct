// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/src/crypto/adb_key_pair.dart';
import 'package:adb_direct/src/crypto/tls_exporter.dart';
import 'package:test/test.dart';

import '../support/hex.dart';
import '../support/tools.dart';

void main() {
  group('TlsExporter.fromKeyLog', () {
    test('picks the EXPORTER_SECRET line and its hash by length', () {
      final exporter = TlsExporter.fromKeyLog([
        'CLIENT_HANDSHAKE_TRAFFIC_SECRET aa ${'11' * 32}',
        'EXPORTER_SECRET ${'00' * 32} ${'22' * 32}\n',
      ]);
      expect(exporter.export(utf8.encode('x'), 16), hasLength(16));
      expect(
        TlsExporter.fromKeyLog(['EXPORTER_SECRET ${'00' * 32} ${'22' * 48}']).export(utf8.encode('x'), 16),
        isNot(exporter.export(utf8.encode('x'), 16)),
      );
    });

    test('refuses logs without a usable secret', () {
      expect(() => TlsExporter.fromKeyLog(const []), throwsFormatException);
      expect(() => TlsExporter.fromKeyLog(['CLIENT_RANDOM aa bb']), throwsFormatException);
      expect(() => TlsExporter.fromKeyLog(['EXPORTER_SECRET aa ${'22' * 20}']), throwsFormatException);
    });

    test('an absent and an empty context are the same in TLS 1.3', () {
      final exporter = TlsExporter.fromKeyLog(['EXPORTER_SECRET ${'00' * 32} ${'33' * 32}']);
      expect(
        exporter.export(utf8.encode('adb-label'), 64),
        exporter.export(utf8.encode('adb-label'), 64, context: const []),
      );
    });
  });

  for (final (suite, hash) in [('TLS_AES_128_GCM_SHA256', 'SHA-256'), ('TLS_AES_256_GCM_SHA384', 'SHA-384')]) {
    test('matches OpenSSL’s exporter on a live TLS 1.3 connection from dart:io ($hash, $suite)', () async {
      final expected = await _exportWithOpenSsl(suite);
      expect(hex(expected.ours), expected.openssl.toLowerCase());
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));
  }
}

/// Connects with `dart:io` to `openssl s_server` restricted to [suite], and returns OpenSSL's exported keying material
/// for `adb-label` (64 bytes) and ours, computed from the key log.
Future<({String openssl, List<int> ours})> _exportWithOpenSsl(String suite) async {
  final temp = await Directory.systemTemp.createTemp('exporter');
  addTearDown(() => temp.delete(recursive: true));
  final identity = AdbKeyPair.fromPem(
    File('test/fixtures/keys/adbkey').readAsStringSync(),
  ).tlsIdentity(now: DateTime.now());
  File('${temp.path}/cert.pem').writeAsStringSync(identity.certificatePem);
  File('${temp.path}/key.pem').writeAsStringSync(identity.privateKeyPem);

  final server = await Process.start(Tools.openssl!, [
    's_server',
    '-tls1_3',
    '-ciphersuites',
    suite,
    '-accept',
    '127.0.0.1:0',
    '-cert',
    '${temp.path}/cert.pem',
    '-key',
    '${temp.path}/key.pem',
    '-keymatexport',
    'adb-label',
    '-keymatexportlen',
    '64',
    '-naccept',
    '1',
  ]);
  addTearDown(() async {
    server.kill();
    await server.exitCode;
  });
  unawaited(server.stderr.drain<void>());

  // OpenSSL picks the port and prints "ACCEPT 127.0.0.1:<port>": no window in which another process could take it.
  final output = StringBuffer();
  final port = Completer<int>();
  final material = Completer<String>();
  server.stdout.transform(utf8.decoder).listen((text) {
    output.write(text);
    final all = output.toString();
    if (!port.isCompleted) {
      final accept = RegExp(r'ACCEPT 127\.0\.0\.1:(\d+)').firstMatch(all);
      if (accept != null) port.complete(int.parse(accept.group(1)!));
    }
    final keying = RegExp(r'Keying material: ([0-9A-F]+)').firstMatch(all);
    if (keying != null && !material.isCompleted) {
      material.complete(keying.group(1));
    }
  });

  final keyLog = <String>[];
  final socket = await SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    await port.future.timeout(const Duration(seconds: 10)),
    onBadCertificate: (_) => true,
    keyLog: keyLog.add,
  );
  final openssl = await material.future.timeout(const Duration(seconds: 10));
  socket.destroy();
  return (openssl: openssl, ours: TlsExporter.fromKeyLog(keyLog).export(utf8.encode('adb-label'), 64));
}
