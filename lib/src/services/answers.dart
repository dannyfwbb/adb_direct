// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';

/// The answer of a service that speaks adb's "smart socket" format:
/// `OKAY` or `FAIL`, then a 4-digit hex length and that much text
/// (`OKAY000542277` → port 42277). Some answers are a bare `OKAY`.
@internal
final class SmartAnswer {
  const SmartAnswer({required this.ok, required this.text});

  /// Parses a complete answer. Throws [AdbProtocolException] when it is not
  /// one.
  factory SmartAnswer.parse(List<int> bytes) {
    final raw = latin1.decode(bytes);
    if (raw.length < 4) {
      throw AdbProtocolException('A truncated service answer: "$raw"');
    }
    final status = raw.substring(0, 4);
    if (status != 'OKAY' && status != 'FAIL') {
      throw AdbProtocolException('An unexpected service answer: "$raw"');
    }
    final rest = raw.substring(4);
    var text = '';
    if (rest.isNotEmpty) {
      text = hexPrefixed(rest);
    }
    return SmartAnswer(ok: status == 'OKAY', text: text);
  }

  /// Whether the device said `OKAY`.
  final bool ok;

  /// The text after the status, often empty.
  final String text;

  /// The text of a `<hex4><text>` frame; throws [AdbProtocolException]
  /// when the length does not match.
  static String hexPrefixed(String frame) {
    if (frame.length < 4) {
      throw AdbProtocolException('A truncated length prefix: "$frame"');
    }
    final length = parseHex4(frame.substring(0, 4));
    if (length == null || frame.length < 4 + length) {
      throw AdbProtocolException('A bad length prefix: "$frame"');
    }
    return utf8.decode(latin1.encode(frame.substring(4, 4 + length)), allowMalformed: true);
  }
}

/// The value of four hex digits, or null for anything else (signs and
/// spaces included, which `int.tryParse` would take).
@internal
int? parseHex4(String text) => RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(text) ? int.parse(text, radix: 16) : null;

/// Opens [service], reads until the device closes it (at most
/// [maxBytes]), and returns what it sent.
@internal
Future<List<int>> readAll(AdbConnection connection, String service, {int maxBytes = 1024 * 1024}) async {
  final stream = await connection.open(service);
  final bytes = <int>[];
  await for (final chunk in stream.input) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) {
      await stream.close();
      throw AdbProtocolException('"$service" answered more than $maxBytes B');
    }
  }
  return bytes;
}
