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

/// Whether [a] and [b] hold the same bytes.
bool sameBytes(List<int> a, List<int> b) => const ListEquality<int>().equals(a, b);
