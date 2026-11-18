// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:meta/meta.dart';

import '../protocol/constants.dart';
import 'adb_public_key.dart';
import 'certificate.dart';
import 'pem.dart';
import 'rsa.dart';

/// The identity a client authenticates with: an RSA-2048 key pair, as desktop adb keeps it in `~/.android/adbkey` and
/// `adbkey.pub`.
///
/// A device trusts a key, not an app or a person: keep the same key pair across sessions, or the device asks its user
/// again. Storing it is the caller's job; [toPem] and [AdbKeyPair.fromPem] are the way in and out, and are compatible
/// with adb's own files.
@immutable
final class AdbKeyPair {
  AdbKeyPair._(this._key, this.comment);

  /// Reads a private key from PEM: PKCS#8 (`BEGIN PRIVATE KEY`, what current adb writes to `adbkey`) or PKCS#1
  /// (`BEGIN RSA PRIVATE KEY`, older adb).
  ///
  /// The key must be a consistent 2048-bit RSA key with an odd public exponent of at least 3 that fits in 32 bits
  /// (adb's keys use 65537). Throws [FormatException] otherwise: bad PEM, another key type, or a key whose numbers do
  /// not fit together.
  factory AdbKeyPair.fromPem(String pem, {String comment = ''}) {
    final List<PemBlock> blocks;
    try {
      blocks = Pem.decode(pem);
    } on FormatException {
      throw const FormatException('PEM text is not valid base64');
    }
    for (final block in blocks) {
      final key = switch (block.label) {
        'PRIVATE KEY' => RsaPrivateKey.fromPkcs8(block.der),
        'RSA PRIVATE KEY' => RsaPrivateKey.fromPkcs1(block.der),
        _ => null,
      };
      if (key != null) return AdbKeyPair._(key, comment);
    }
    throw const FormatException('No RSA private key in the PEM text');
  }

  /// Generates a new key pair in a background isolate (key generation takes seconds in pure Dart).
  ///
  /// [comment] is what the device shows next to the key, conventionally `user@host`.
  static Future<AdbKeyPair> generate({String comment = ''}) async {
    final key = await Isolate.run(RsaPrivateKey.generate);
    return AdbKeyPair._(key, comment);
  }

  final RsaPrivateKey _key;

  /// The comment sent with the public key, conventionally `user@host`.
  final String comment;

  /// The public half, in adb's format, with [comment].
  AdbPublicKey get publicKey => AdbPublicKey(modulus: _key.modulus, exponent: _key.publicExponent, comment: comment);

  /// The same key with another [comment].
  AdbKeyPair withComment(String comment) => AdbKeyPair._(_key, comment);

  /// The private key as PKCS#8 PEM, the format of adb's `adbkey`.
  String toPem() => Pem.encode('PRIVATE KEY', _key.toPkcs8());

  /// SHA-256 of the DER `SubjectPublicKeyInfo`, uppercase hex: how a device names this key in the trusted-key list it
  /// sends during a TLS handshake.
  String get spkiSha256 => hashes.sha256
      .convert(_key.subjectPublicKeyInfo())
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  /// Signs the 20-byte token of an `AUTH` challenge the way adb does: PKCS#1 v1.5 with the SHA-1 `DigestInfo`, the
  /// token standing in for the digest (it is not hashed again).
  @internal
  Uint8List signAuthToken(List<int> token) {
    if (token.length != AdbProtocol.authTokenLength) {
      throw ArgumentError.value(token.length, 'token', 'an AUTH token has ${AdbProtocol.authTokenLength} bytes');
    }
    return _key.signDigest(sha1DigestInfoPrefix, token);
  }

  /// The certificate and key to present in TLS, valid from [now].
  @internal
  TlsIdentity tlsIdentity({required DateTime now}) => buildTlsIdentity(_key, now: now);

  static final Expando<TlsIdentity> _tls = Expando('adb_direct TLS identity');

  /// The certificate this key pair object presents in TLS: made on first use (valid for ten years from then, as adb's)
  /// and reused for the life of the object, so no RSA signature is spent per connection. Another object for the same
  /// key, or a new process, makes a new one; devices check only the public key.
  @internal
  TlsIdentity get tls => _tls[this] ??= buildTlsIdentity(_key, now: DateTime.now().toUtc());

  /// Equal when the keys and the comments are equal. Compares public values only: the modulus determines the private
  /// key.
  @override
  bool operator ==(Object other) =>
      other is AdbKeyPair &&
      other._key.modulus == _key.modulus &&
      other._key.publicExponent == _key.publicExponent &&
      other.comment == comment;

  @override
  int get hashCode => Object.hash(_key.modulus, comment);

  @override
  String toString() =>
      'AdbKeyPair(${publicKey.md5Fingerprint}'
      '${comment.isEmpty ? '' : ' $comment'})';
}
