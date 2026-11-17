// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:adb_direct/src/crypto/hkdf.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

List<int> unhex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // RFC 5869 appendix A, test cases 1-3 (SHA-256).
  test('RFC 5869 A.1 basic', () {
    final prk = Hkdf.extract(
      sha256,
      unhex('0b' * 22),
      salt: unhex('000102030405060708090a0b0c'),
    );
    expect(
      hex(prk),
      '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5',
    );
    expect(
      hex(Hkdf.expand(sha256, prk, unhex('f0f1f2f3f4f5f6f7f8f9'), 42)),
      '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
      '34007208d5b887185865',
    );
  });

  test('RFC 5869 A.2 longer inputs and outputs', () {
    final okm = Hkdf.derive(
      sha256,
      unhex(
        [for (var i = 0x00; i <= 0x4f; i++) i.toRadixString(16).padLeft(2, '0')]
            .join(),
      ),
      salt: unhex(
        [for (var i = 0x60; i <= 0xaf; i++) i.toRadixString(16).padLeft(2, '0')]
            .join(),
      ),
      info: unhex(
        [for (var i = 0xb0; i <= 0xff; i++) i.toRadixString(16).padLeft(2, '0')]
            .join(),
      ),
      length: 82,
    );
    expect(
      hex(okm),
      'b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
      '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
      'cc30c58179ec3e87c14c01d5c1f3434f1d87',
    );
  });

  test('RFC 5869 A.3 empty salt and info', () {
    final okm = Hkdf.derive(
      sha256,
      unhex('0b' * 22),
      info: const [],
      length: 42,
    );
    expect(
      hex(okm),
      '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
      '9d201395faa4b61a96c8',
    );
  });

  test('refuses lengths above 255 blocks', () {
    expect(
      () => Hkdf.expand(sha256, List.filled(32, 1), const [], 255 * 32 + 1),
      throwsRangeError,
    );
  });
}
