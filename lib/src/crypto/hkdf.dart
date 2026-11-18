// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF (RFC 5869) over an HMAC [hash].
abstract final class Hkdf {
  /// HKDF-Extract: a pseudorandom key from [inputKeyMaterial] and [salt] (all-zero, hash-sized, when empty).
  static Uint8List extract(Hash hash, List<int> inputKeyMaterial, {List<int> salt = const []}) {
    final key = salt.isEmpty ? List<int>.filled(_hashLength(hash), 0) : salt;
    return Uint8List.fromList(Hmac(hash, key).convert(inputKeyMaterial).bytes);
  }

  /// HKDF-Expand: [length] bytes from a pseudorandom key and [info].
  static Uint8List expand(Hash hash, List<int> pseudorandomKey, List<int> info, int length) {
    final hashLength = _hashLength(hash);
    if (length < 0 || length > 255 * hashLength) {
      throw RangeError.range(length, 0, 255 * hashLength, 'length');
    }
    final hmac = Hmac(hash, pseudorandomKey);
    final out = BytesBuilder(copy: false);
    var block = <int>[];
    for (var counter = 1; out.length < length; counter++) {
      block = hmac.convert([...block, ...info, counter]).bytes;
      out.add(block);
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  /// Extract then expand.
  static Uint8List derive(
    Hash hash,
    List<int> inputKeyMaterial, {
    required List<int> info,
    required int length,
    List<int> salt = const [],
  }) => expand(hash, extract(hash, inputKeyMaterial, salt: salt), info, length);

  static int _hashLength(Hash hash) => hash.convert(const []).bytes.length;
}
