// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hkdf.dart';

/// TLS 1.3 keying material exporter (RFC 8446 7.5), computed from the
/// `EXPORTER_SECRET` that `dart:io` reports through `keyLog`.
///
/// `dart:io` exposes no exporter, but its key log carries the exporter
/// master secret in the NSS key-log format. Pairing needs 64 bytes with the
/// label `adb-label\0`; this was checked byte for byte against OpenSSL's
/// exporter.
final class TlsExporter {
  TlsExporter._(this._secret, this._hash);

  /// Finds the `EXPORTER_SECRET` among the key-log [lines] of one TLS 1.3
  /// connection.
  ///
  /// The hash is the cipher suite's: SHA-256 for a 32-byte secret, SHA-384
  /// for a 48-byte one. Throws [FormatException] when no usable line is
  /// there (for example on TLS 1.2, which has no exporter secret).
  factory TlsExporter.fromKeyLog(Iterable<String> lines) {
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 3 || parts[0] != 'EXPORTER_SECRET') continue;
      final secret = _hex(parts[2]);
      final hash = switch (secret.length) {
        32 => sha256,
        48 => sha384,
        _ => throw FormatException('EXPORTER_SECRET of ${secret.length} bytes'),
      };
      return TlsExporter._(secret, hash);
    }
    throw const FormatException('No EXPORTER_SECRET in the TLS key log');
  }

  final Uint8List _secret;
  final Hash _hash;

  /// `TLS-Exporter(label, context, length)`:
  /// `HKDF-Expand-Label(Derive-Secret(secret, label, ""), "exporter",
  /// Hash(context), length)`.
  ///
  /// [label] is bytes because adb's includes its terminating NUL. An absent
  /// context and an empty one give the same result in TLS 1.3.
  Uint8List export(
    List<int> label,
    int length, {
    List<int> context = const [],
  }) {
    final emptyHash = _hash.convert(const []).bytes;
    final derived = _expandLabel(_secret, label, emptyHash, emptyHash.length);
    return _expandLabel(
      derived,
      utf8.encode('exporter'),
      _hash.convert(context).bytes,
      length,
    );
  }

  Uint8List _expandLabel(
    List<int> secret,
    List<int> label,
    List<int> context,
    int length,
  ) {
    final fullLabel = [...utf8.encode('tls13 '), ...label];
    if (fullLabel.length > 255 || context.length > 255) {
      throw ArgumentError('Label or context too long');
    }
    final info = [
      length >> 8,
      length & 0xff,
      fullLabel.length,
      ...fullLabel,
      context.length,
      ...context,
    ];
    return Hkdf.expand(_hash, secret, info, length);
  }

  static Uint8List _hex(String hex) {
    if (hex.length.isOdd) throw const FormatException('Odd-length hex');
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }
}
