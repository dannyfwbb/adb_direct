// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart';
import '../errors.dart';

/// The answer of a service that speaks adb's "smart socket" format: `OKAY` or `FAIL`, then a 4-digit hex length and
/// that much text (`OKAY000542277` → port 42277). Some answers are a bare `OKAY`.
@internal
final class SmartAnswer {
  const SmartAnswer({required this.ok, required this.text});

  /// Parses a complete answer. Throws [AdbProtocolException] when it is not one.
  factory SmartAnswer.parse(List<int> bytes) {
    final status = bytes.length < 4 ? null : latin1.decode(bytes.sublist(0, 4));
    if (status != 'OKAY' && status != 'FAIL') {
      throw AdbProtocolException('An unexpected service answer: "${latin1.decode(bytes)}"');
    }
    return SmartAnswer(ok: status == 'OKAY', text: bytes.length == 4 ? '' : hexPrefixed(bytes.sublist(4)));
  }

  /// Whether the device said `OKAY`.
  final bool ok;

  /// The text after the status, often empty.
  final String text;

  /// The text of a `<hex4><text>` frame; throws [AdbProtocolException] when the length does not match.
  static String hexPrefixed(List<int> frame) {
    final length = frame.length < 4 ? null : parseHex4(latin1.decode(frame.sublist(0, 4)));
    if (length == null || frame.length < 4 + length) {
      throw AdbProtocolException('A bad length prefix: "${latin1.decode(frame)}"');
    }
    return utf8.decode(frame.sublist(4, 4 + length), allowMalformed: true);
  }
}

/// The value of four hex digits, or null for anything else (signs and spaces included, which `int.tryParse` would
/// take).
@internal
int? parseHex4(String text) => RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(text) ? int.parse(text, radix: 16) : null;

/// Opens [service], reads until the device closes it (at most [maxBytes]), and returns what it sent.
///
/// A device that keeps the stream open past [timeout] (the open included) gets it closed, and the call throws
/// [AdbTimeoutException]; the connection stays usable.
@internal
Future<Uint8List> readAll(
  AdbConnection connection,
  String service, {
  int maxBytes = 1024 * 1024,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final stream = connection.openStream(service);

  Future<Uint8List> collect() async {
    await stream.opened;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream.input) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        await stream.close();
        throw AdbProtocolException('"$service" answered more than $maxBytes B');
      }
    }
    return bytes.takeBytes();
  }

  return connection.clock.deadline(collect(), timeout, () {
    unawaited(stream.close());
    return AdbTimeoutException('"$service" did not answer within $timeout');
  });
}
