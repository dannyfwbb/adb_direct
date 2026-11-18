// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/src/crypto/adb_key_pair.dart';
import 'package:adb_direct/src/crypto/adb_public_key.dart';
import 'package:adb_direct/src/crypto/der.dart';
import 'package:adb_direct/src/crypto/pem.dart';
import 'package:adb_direct/src/crypto/rsa.dart';
import 'package:test/test.dart';

import '../support/tools.dart';

/// A test-only key pair made with `adb keygen` (never trusted by any device), with adb's own public key file for it.
final String keyPem = File('test/fixtures/keys/adbkey').readAsStringSync();
final String keyPkcs1Pem = File('test/fixtures/keys/adbkey_pkcs1.pem').readAsStringSync();
final String adbPub = File('test/fixtures/keys/adbkey.pub').readAsStringSync();

void main() {
  late Directory temp;
  setUpAll(() async => temp = await Directory.systemTemp.createTemp('adbkey'));
  tearDownAll(() => temp.delete(recursive: true));

  group('reading adb keys', () {
    test('PKCS#8 adbkey gives exactly the adbkey.pub adb wrote', () {
      final pair = AdbKeyPair.fromPem(keyPem, comment: 'test@adb_direct');
      expect(pair.publicKey.encode(), adbPub);
    });

    test('PKCS#1 (older adb) gives the same key', () {
      expect(AdbKeyPair.fromPem(keyPkcs1Pem).publicKey, AdbKeyPair.fromPem(keyPem).publicKey);
    });

    test('PEM round trip is byte-identical', () {
      final pair = AdbKeyPair.fromPem(keyPem);
      expect(pair.toPem(), keyPem);
    });

    test('non-RSA or malformed PEM is refused', () {
      expect(() => AdbKeyPair.fromPem('nothing here'), throwsFormatException);
      expect(
        () => AdbKeyPair.fromPem('-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----'),
        throwsFormatException,
      );
    });
  });

  group('AdbPublicKey', () {
    test('parses adbkey.pub and re-encodes it', () {
      final key = AdbPublicKey.parse(adbPub);
      expect(key.comment, 'test@adb_direct');
      expect(key.exponent, BigInt.from(65537));
      expect(key.encode(), adbPub);
    });

    test('accepts the NUL-terminated form sent in AUTH', () {
      expect(AdbPublicKey.parse('$adbPub\u0000'), AdbPublicKey.parse(adbPub));
    });

    test('rejects a structure with a tampered rr field', () {
      final bytes = AdbPublicKey.parse(adbPub).toBytes();
      bytes[300] ^= 1;
      expect(() => AdbPublicKey.fromBytes(bytes), throwsFormatException);
    });

    test('MD5 fingerprint has the format of the device dialog', () {
      final fingerprint = AdbPublicKey.parse(adbPub).md5Fingerprint;
      expect(fingerprint, matches(RegExp(r'^([0-9A-F]{2}:){15}[0-9A-F]{2}$')));
    });
  });

  group('signing AUTH tokens', () {
    final pair = AdbKeyPair.fromPem(keyPem);

    test('refuses tokens that are not 20 bytes', () {
      expect(() => pair.signAuthToken(List.filled(19, 0)), throwsArgumentError);
    });

    test('matches openssl pkeyutl -pkeyopt digest:sha1 for random tokens', () async {
      final keyFile = File('${temp.path}/sign.pem')..writeAsStringSync(keyPem);
      final random = Random(7);
      for (var i = 0; i < 5; i++) {
        final token = Uint8List.fromList(List.generate(20, (_) => random.nextInt(256)));
        final expected = await Tools.runBytes(Tools.openssl!, [
          'pkeyutl',
          '-sign',
          '-inkey',
          keyFile.path,
          '-pkeyopt',
          'digest:sha1',
        ], stdin: token);
        expect(pair.signAuthToken(token), expected);
      }
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));
  });

  group('interoperability with adb', () {
    test('adb pubkey derives our public key from our PEM', () async {
      final keyFile = File('${temp.path}/ours.pem')..writeAsStringSync(AdbKeyPair.fromPem(keyPem).toPem());
      final printed = await Tools.run(Tools.adb!, ['pubkey', keyFile.path]);
      expect(printed.trim().split(' ').first, AdbKeyPair.fromPem(keyPem).publicKey.encode());
    }, skip: Tools.skipUnless(Tools.adb, 'adb'));

    test(
      'a freshly generated key is read by openssl and adb',
      () async {
        final stopwatch = Stopwatch()..start();
        final pair = await AdbKeyPair.generate(comment: 'gen@test');
        final elapsed = stopwatch.elapsed;
        printOnFailure('key generation took $elapsed');

        final keyFile = File('${temp.path}/generated.pem')..writeAsStringSync(pair.toPem());
        final check = await Tools.run(Tools.openssl!, ['pkey', '-in', keyFile.path, '-check', '-noout']);
        expect(check, contains('Key is valid'));
        final bits = await Tools.run(Tools.openssl!, ['pkey', '-in', keyFile.path, '-text', '-noout']);
        expect(bits, contains('2048 bit'));
        expect(bits, contains('publicExponent: 65537'));
        if (Tools.adb case final adb?) {
          final printed = await Tools.run(adb, ['pubkey', keyFile.path]);
          expect(printed.trim().split(' ').first, pair.publicKey.encode().split(' ').first);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: Tools.skipUnless(Tools.openssl, 'openssl'),
    );
  });

  group('keys that do not fit together are refused on import', () {
    final good = RsaPrivateKey.fromPkcs8(Pem.decode(keyPem).single.der);

    String pkcs1(List<BigInt> fields) =>
        Pem.encode('RSA PRIVATE KEY', Der.sequence([Der.smallInteger(0), for (final f in fields) Der.integer(f)]));

    List<BigInt> fieldsOf(RsaPrivateKey k) => [
      k.modulus,
      k.publicExponent,
      k.privateExponent,
      k.p,
      k.q,
      k.dP,
      k.dQ,
      k.qInv,
    ];

    void refused(String name, List<BigInt> fields) {
      test(name, () {
        expect(() => AdbKeyPair.fromPem(pkcs1(fields)), throwsFormatException);
      });
    }

    final f = fieldsOf(good);
    refused('a wrong public exponent (3 with the d of 65537)', [f[0], BigInt.from(3), ...f.sublist(2)]);
    refused('a wrong private exponent', [f[0], f[1], f[2] + BigInt.two, ...f.sublist(3)]);
    refused('an even public exponent', [f[0], BigInt.from(65538), ...f.sublist(2)]);
    refused('a wrong CRT value', [...f.sublist(0, 5), f[5] + BigInt.one, f[6], f[7]]);
    refused('factors that do not multiply to the modulus', [f[0], f[1], f[2], f[3] + BigInt.two, ...f.sublist(4)]);
    refused('p equal to q', [f[3] * f[3], f[1], f[2], f[3], f[3], ...f.sublist(5)]);
    refused('p = 1, q = n', [f[0], f[1], f[2], BigInt.one, f[0], ...f.sublist(5)]);
    refused('extra fields (multi-prime)', [...f, BigInt.one]);

    test('a 1024-bit key', () async {
      final pem = await Tools.run(Tools.openssl!, ['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:1024']);
      expect(() => AdbKeyPair.fromPem(pem), throwsFormatException);
    }, skip: Tools.skipUnless(Tools.openssl, 'openssl'));

    test('a PKCS#8 file with an empty or foreign algorithm', () {
      for (final algorithm in [
        Der.sequence(const []),
        Der.sequence([Der.objectIdentifier('1.2.840.10045.2.1')]),
        Der.sequence([Der.objectIdentifier(rsaEncryptionOid), Der.smallInteger(1)]),
      ]) {
        final pem = Pem.encode(
          'PRIVATE KEY',
          Der.sequence([Der.smallInteger(0), algorithm, Der.octetString(good.toPkcs1())]),
        );
        expect(() => AdbKeyPair.fromPem(pem), throwsFormatException);
      }
    });

    test('garbage inside a PEM block', () {
      expect(
        () => AdbKeyPair.fromPem('-----BEGIN PRIVATE KEY-----\n!!!!\n-----END PRIVATE KEY-----'),
        throwsFormatException,
      );
    });
  });

  group('public keys that cannot be adb keys are refused', () {
    final key = AdbPublicKey.parse(adbPub);

    test('an even modulus', () {
      expect(() => AdbPublicKey(modulus: key.modulus + BigInt.one, exponent: key.exponent), throwsArgumentError);
    });

    test('an even or tiny exponent', () {
      for (final e in [2, 1, 65538]) {
        expect(() => AdbPublicKey(modulus: key.modulus, exponent: BigInt.from(e)), throwsArgumentError);
      }
    });

    test('a hostile adbkey.pub is a FormatException, not a crash', () {
      final bytes = key.toBytes();
      bytes[8] &= 0xfe; // Even modulus.
      expect(() => AdbPublicKey.fromBytes(bytes), throwsFormatException);
      expect(() => AdbPublicKey.parse('QUJD user@host'), throwsFormatException);
      expect(() => AdbPublicKey.parse('%%% user@host'), throwsFormatException);
    });

    test('hasSameKey ignores the comment, == does not', () {
      final other = AdbPublicKey.parse('${adbPub.split(' ').first} other@host');
      expect(other.hasSameKey(key), isTrue);
      expect(other, isNot(key));
    });
  });

  test('the user’s own ~/.android/adbkey yields its adbkey.pub (set ADB_DIRECT_TEST_ADBKEY_DIR to run)', () {
    final dir = Platform.environment['ADB_DIRECT_TEST_ADBKEY_DIR']!;
    final pub = File('$dir/adbkey.pub').readAsStringSync().trim();
    final comment = pub.substring(pub.indexOf(' ') + 1);
    final pair = AdbKeyPair.fromPem(File('$dir/adbkey').readAsStringSync(), comment: comment);
    expect(pair.publicKey.encode(), pub);
  }, skip: Platform.environment['ADB_DIRECT_TEST_ADBKEY_DIR'] == null ? 'ADB_DIRECT_TEST_ADBKEY_DIR is not set' : null);

  test('withComment keeps the key', () {
    final pair = AdbKeyPair.fromPem(keyPem);
    final renamed = pair.withComment('other@host');
    expect(renamed.publicKey.modulus, pair.publicKey.modulus);
    expect(renamed.publicKey.comment, 'other@host');
    expect(renamed, isNot(pair));
  });
}
