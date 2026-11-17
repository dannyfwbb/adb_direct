// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:meta/meta.dart';

import 'der.dart';

/// An RSA public key in the form adb and adbd exchange: a 524-byte
/// structure in base64, followed by a comment such as `user@host`.
///
/// This is the format of `adbkey.pub` and of the key a device shows in
/// "Allow debugging?".
@immutable
final class AdbPublicKey {
  /// Creates a key from its RSA modulus and exponent.
  ///
  /// Throws [ArgumentError] unless the modulus is an odd 2048-bit number
  /// and the exponent is odd, at least 3 and fits in 32 bits.
  AdbPublicKey({
    required this.modulus,
    required this.exponent,
    this.comment = '',
  }) {
    if (modulus.bitLength != _modulusBytes * 8 || modulus.isEven) {
      throw ArgumentError.value(
        modulus.bitLength,
        'modulus',
        'adb keys are 2048-bit RSA with an odd modulus',
      );
    }
    if (exponent.isEven ||
        exponent < BigInt.from(3) ||
        exponent.bitLength > 32) {
      throw ArgumentError.value(
        exponent,
        'exponent',
        'must be odd, at least 3 and fit in 32 bits',
      );
    }
  }

  /// Parses `<base64> <comment>`, the content of an `adbkey.pub` file or
  /// of an `AUTH` public key payload (a trailing NUL is allowed).
  ///
  /// Throws [FormatException] for anything that is not a valid adb key.
  factory AdbPublicKey.parse(String text) {
    final trimmed = text.replaceAll('\u0000', '').trim();
    final space = trimmed.indexOf(RegExp(r'\s'));
    final encoded = space < 0 ? trimmed : trimmed.substring(0, space);
    final comment = space < 0 ? '' : trimmed.substring(space + 1).trim();
    final Uint8List bytes;
    try {
      bytes = base64.decode(encoded);
    } on FormatException {
      throw const FormatException('adb public key is not valid base64');
    }
    return AdbPublicKey.fromBytes(bytes, comment: comment);
  }

  /// Decodes the 524-byte structure. Throws [FormatException] when it is
  /// malformed or inconsistent.
  factory AdbPublicKey.fromBytes(List<int> bytes, {String comment = ''}) {
    if (bytes.length != encodedLength) {
      throw FormatException(
        'adb public key has ${bytes.length} bytes; expected $encodedLength',
      );
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (data.getUint32(0, Endian.little) != _modulusWords) {
      throw const FormatException('adb public key is not 2048-bit');
    }
    final modulus = _littleEndian(bytes.sublist(8, 8 + _modulusBytes));
    final AdbPublicKey key;
    try {
      key = AdbPublicKey(
        modulus: modulus,
        exponent: BigInt.from(data.getUint32(520, Endian.little)),
        comment: comment,
      );
    } on ArgumentError catch (e) {
      throw FormatException('Invalid adb public key: ${e.message}');
    }
    if (!_sameBytes(key.toBytes(), bytes)) {
      throw const FormatException(
        'adb public key has inconsistent n0inv or rr fields',
      );
    }
    return key;
  }

  /// Size of the binary structure.
  static const int encodedLength = 524;

  static const int _modulusBytes = 256;
  static const int _modulusWords = _modulusBytes ~/ 4;

  /// n.
  final BigInt modulus;

  /// e.
  final BigInt exponent;

  /// The text after the key, conventionally `user@host`. Empty if none.
  final String comment;

  /// The 524-byte structure: word count, n0inv = −n⁻¹ mod 2³², n and
  /// rr = (2²⁰⁴⁸)² mod n in little-endian, then the exponent.
  Uint8List toBytes() {
    final out = Uint8List(encodedLength);
    final data = ByteData.sublistView(out);
    final twoTo32 = BigInt.one << 32;
    final n0inv = (twoTo32 - modulus.modInverse(twoTo32)) % twoTo32;
    final rr = (BigInt.one << (2 * _modulusBytes * 8)) % modulus;
    data
      ..setUint32(0, _modulusWords, Endian.little)
      ..setUint32(4, n0inv.toInt(), Endian.little)
      ..setUint32(520, exponent.toInt(), Endian.little);
    out
      ..setRange(8, 8 + _modulusBytes, _toLittleEndian(modulus))
      ..setRange(264, 264 + _modulusBytes, _toLittleEndian(rr));
    return out;
  }

  /// `<base64> <comment>` as in `adbkey.pub` (no trailing newline or NUL).
  String encode() {
    final key = base64.encode(toBytes());
    return comment.isEmpty ? key : '$key $comment';
  }

  /// The fingerprint a device shows in "Allow debugging?": MD5 of the
  /// 524-byte structure, uppercase hex bytes separated by colons.
  String get md5Fingerprint => hashes.md5
      .convert(toBytes())
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  /// Whether [other] is the same RSA key, whatever the comments say. A
  /// device identifies a client by this alone.
  bool hasSameKey(AdbPublicKey other) =>
      other.modulus == modulus && other.exponent == exponent;

  /// Equal when the key and the comment are equal; see [hasSameKey] to
  /// compare keys only.
  @override
  bool operator ==(Object other) =>
      other is AdbPublicKey &&
      other.modulus == modulus &&
      other.exponent == exponent &&
      other.comment == comment;

  @override
  int get hashCode => Object.hash(modulus, exponent, comment);

  @override
  String toString() =>
      'AdbPublicKey($md5Fingerprint'
      '${comment.isEmpty ? '' : ' $comment'})';

  static Uint8List _toLittleEndian(BigInt value) {
    final bigEndian = Der.unsignedBytes(value, length: _modulusBytes);
    return Uint8List.fromList(bigEndian.reversed.toList());
  }

  static BigInt _littleEndian(List<int> bytes) =>
      Der.unsignedValue(bytes.reversed.toList());

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
