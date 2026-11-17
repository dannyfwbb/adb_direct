// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/src/crypto/ed25519.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

final BigInt p = (BigInt.one << 255) - BigInt.from(19);
final BigInt l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

BigInt randomBelow(Random r, BigInt n) {
  var v = BigInt.zero;
  for (var i = 0; i < 40; i++) {
    v = (v << 8) | BigInt.from(r.nextInt(256));
  }
  return v % n;
}

BigInt fromLe(List<int> b) {
  var n = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    n = (n << 8) | BigInt.from(b[i]);
  }
  return n;
}

/// RFC 8032 public key: SHA-512 of the seed, clamped low half times B.
Uint8List publicKey(List<int> seed) {
  final h = sha512.convert(seed).bytes.sublist(0, 32);
  h[0] &= 248;
  h[31] &= 127;
  h[31] |= 64;
  return EdPoint.base.multiply(h).encode();
}

void main() {
  group('field arithmetic against BigInt', () {
    final r = Random(25519);
    test('round trip, edges included', () {
      for (final n in [
        BigInt.zero,
        BigInt.one,
        p - BigInt.one,
        p,
        p + BigInt.one,
        (BigInt.one << 255) - BigInt.one,
      ]) {
        expect(fieldRoundTrip(n), n % p, reason: '$n');
      }
    });

    test('multiply, subtract, invert', () {
      for (var i = 0; i < 200; i++) {
        final a = randomBelow(r, p);
        final b = randomBelow(r, p);
        expect(fieldMultiply(a, b), a * b % p);
        expect(fieldSubtract(a, b), (a - b) % p);
        if (a != BigInt.zero) expect(fieldInvert(a), a.modInverse(p));
      }
      expect(fieldMultiply(p - BigInt.one, p - BigInt.one), BigInt.one);
    });
  });

  group('scalars', () {
    test('64-byte reduction modulo l matches BigInt', () {
      final r = Random(8032);
      for (var i = 0; i < 300; i++) {
        final x = Uint8List.fromList(List.generate(64, (_) => r.nextInt(256)));
        if (i == 0) x.fillRange(0, 64, 0xff);
        if (i == 1) x.fillRange(0, 64, 0);
        expect(fromLe(reduceScalar(x)), fromLe(x) % l);
      }
    });

    test('multiplying leaves the point alone, even with bit 255 set', () {
      final before = EdPoint.base.encode();
      EdPoint.base.multiply(Uint8List(32)..fillRange(0, 32, 0xff));
      expect(EdPoint.base.encode(), before);
    });

    test('the order is l', () {
      expect(fromLe(groupOrder), l);
      expect(
        EdPoint.base.multiply(groupOrder).equals(EdPoint.identity()),
        isTrue,
      );
    });
  });

  group('points', () {
    test('RFC 8032 section 7.1 public keys', () {
      // TEST 1, 2, 3 and 1024.
      const vectors = {
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60':
            'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb':
            '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7':
            'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        'f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5':
            '278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e',
      };
      vectors.forEach((seed, key) {
        expect(hex(publicKey(unhex(seed))), key);
      });
    });

    test('decode and encode round trip; group laws', () {
      final b = EdPoint.base;
      expect(EdPoint.decode(b.encode())!.equals(b), isTrue);
      final two = Uint8List(32)..[0] = 2;
      final three = Uint8List(32)..[0] = 3;
      expect((b + b).equals(b.multiply(two)), isTrue);
      expect((b + b + b - b).equals(b.multiply(two)), isTrue);
      expect(b.multiply(three).equals(b + b + b), isTrue);
      expect((b - b).equals(EdPoint.identity()), isTrue);
    });

    test(
      'y = 2 has no point; non-canonical y is accepted as BoringSSL does',
      () {
        expect(EdPoint.decode(Uint8List(32)..[0] = 2), isNull);
        // y = p + 1 reads as y = 1, the identity.
        final pPlusOne = Uint8List(32);
        var v = p + BigInt.one;
        for (var i = 0; i < 32; i++) {
          pPlusOne[i] = (v & BigInt.from(0xff)).toInt();
          v >>= 8;
        }
        expect(EdPoint.decode(pPlusOne)!.equals(EdPoint.identity()), isTrue);
        expect(EdPoint.decode(Uint8List(31)), isNull);
      },
    );
  });
}
