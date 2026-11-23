// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:adb_direct/src/crypto/adb_key_pair.dart';
import 'package:test/test.dart';

import '../support/tools.dart';

void main() {
  final pair = AdbKeyPair.fromPem(File('test/fixtures/keys/adbkey').readAsStringSync());
  final now = DateTime.utc(2026, 11, 17, 12, 30, 45, 999);
  final identity = pair.tlsIdentity(now: now);

  late Directory temp;
  setUpAll(() async => temp = await Directory.systemTemp.createTemp('cert'));
  tearDownAll(() => temp.delete(recursive: true));

  Future<String> openssl(List<String> args) => Tools.run(Tools.openssl!, args);

  group('the TLS certificate', () {
    test('is made once per key object, at the time given', () {
      final key = AdbKeyPair.fromPem(pair.toPem());
      final first = key.tls(() => now);
      expect(first.certificatePem, identity.certificatePem);
      expect(key.tls(() => DateTime.utc(2030)), same(first));
    });

    test('has the fields adb puts in its own', () async {
      final file = File('${temp.path}/cert.pem')..writeAsStringSync(identity.certificatePem);
      final text = await openssl(['x509', '-in', file.path, '-noout', '-text']);
      expect(text, contains('Version: 3 (0x2)'));
      expect(text, contains('Serial Number: 1 (0x1)'));
      expect(text, contains('Signature Algorithm: sha256WithRSAEncryption'));
      expect(text, contains('Issuer: C=US, O=Android, CN=Adb'));
      expect(text, contains('Subject: C=US, O=Android, CN=Adb'));
      expect(text, contains('Not Before: Nov 17 12:30:45 2026 GMT'));
      expect(text, contains('Not After : Nov 14 12:30:45 2036 GMT'));
      expect(text, contains('Public-Key: (2048 bit)'));
      expect(text, contains('X509v3 Basic Constraints: critical'));
      expect(text, contains('CA:TRUE'));
      expect(text, contains('X509v3 Key Usage: critical'));
      expect(text, contains('Digital Signature, Certificate Sign, CRL Sign'));
      expect(text, contains('X509v3 Subject Key Identifier'));
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

    test('its signature verifies (self-signed CA)', () async {
      final file = File('${temp.path}/verify.pem')..writeAsStringSync(identity.certificatePem);
      final result = await openssl([
        'verify',
        '-attime',
        '${now.millisecondsSinceEpoch ~/ 1000 + 60}',
        '-CAfile',
        file.path,
        file.path,
      ]);
      expect(result.trim(), endsWith(': OK'));
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

    test('its subject key identifier is the SHA-1 of the public key', () async {
      final file = File('${temp.path}/ski.pem')..writeAsStringSync(identity.certificatePem);
      final text = await openssl(['x509', '-in', file.path, '-noout', '-ext', 'subjectKeyIdentifier']);
      final keyFile = File('${temp.path}/ski.key')..writeAsStringSync(identity.privateKeyPem);
      // openssl computes the "hash" method itself from the key.
      final reference = await openssl([
        'req',
        '-new',
        '-x509',
        '-key',
        keyFile.path,
        '-subj',
        '/CN=x',
        '-addext',
        'subjectKeyIdentifier=hash',
        '-noout',
        '-text',
      ]);
      final ours = RegExp(r'([0-9A-F]{2}:){19}[0-9A-F]{2}').firstMatch(text)!;
      expect(reference, contains(ours.group(0)));
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

    test('the private key PEM is the key pair’s', () async {
      final file = File('${temp.path}/key.pem')..writeAsStringSync(identity.privateKeyPem);
      final modulus = await openssl(['rsa', '-in', file.path, '-noout', '-modulus']);
      expect(BigInt.parse(modulus.trim().split('=').last, radix: 16), pair.publicKey.modulus);
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));
  });

  test('spkiSha256 matches openssl over the DER public key', () async {
    final file = File('${temp.path}/spki.pem')..writeAsStringSync(identity.privateKeyPem);
    final der = await Tools.runBytes(Tools.openssl!, ['pkey', '-in', file.path, '-pubout', '-outform', 'DER']);
    final digest = await Tools.run(Tools.openssl!, ['dgst', '-sha256', '-hex'], stdin: der);
    expect(digest.trim().split(' ').last.toUpperCase(), pair.spkiSha256);
  }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));
}
