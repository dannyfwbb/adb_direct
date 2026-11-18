// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Byte helpers shared across the library.
@internal
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

final Random _random = Random.secure();

/// [length] bytes from the system's secure random source.
Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

/// A random name part: [length] bytes as lowercase hex.
String randomHex([int length = 4]) => hexEncode(randomBytes(length));

/// [bytes] as lowercase hex, two digits each, joined with [separator].
String hexEncode(List<int> bytes, {String separator = ''}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(separator);

/// The bytes of an even-length hex string. Throws [FormatException] for anything else.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) throw FormatException('Odd-length hex', hex);
  return Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Four ASCII letters as the little-endian 32-bit value ADB and sync ids use on the wire (`CNXN`, `STAT`).
int fourCc(String letters) =>
    letters.codeUnitAt(0) |
    (letters.codeUnitAt(1) << 8) |
    (letters.codeUnitAt(2) << 16) |
    (letters.codeUnitAt(3) << 24);

/// The letters of a [fourCc] value.
String fourCcName(int value) =>
    String.fromCharCodes([value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff]);

/// Whether [a] and [b] hold the same bytes.
bool sameBytes(List<int> a, List<int> b) => const ListEquality<int>().equals(a, b);
