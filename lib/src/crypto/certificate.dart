// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import 'der.dart';
import 'pem.dart';
import 'rsa.dart';

/// The certificate and key a client presents in TLS (wireless debugging
/// connections and pairing).
final class TlsIdentity {
  /// Creates an identity.
  const TlsIdentity({required this.certificateDer, required this.key});

  /// The self-signed certificate, DER.
  final Uint8List certificateDer;

  /// The private key it certifies.
  final RsaPrivateKey key;

  /// The certificate as PEM, for `SecurityContext.useCertificateChainBytes`.
  String get certificatePem => Pem.encode('CERTIFICATE', certificateDer);

  /// The key as PKCS#8 PEM, for `SecurityContext.usePrivateKeyBytes`.
  String get privateKeyPem => Pem.encode('PRIVATE KEY', key.toPkcs8());
}

/// Builds the certificate adb builds from its key: X.509 v3, serial 1,
/// subject and issuer `C=US, O=Android, CN=Adb`, valid from [now] for ten
/// years, `basicConstraints` CA (critical), `keyUsage` digitalSignature,
/// keyCertSign and cRLSign (critical), `subjectKeyIdentifier`, signed with
/// SHA-256. adbd identifies the client by the key alone; the fields follow
/// adb so nothing about the certificate stands out.
TlsIdentity buildTlsIdentity(RsaPrivateKey key, {required DateTime now}) {
  final notBefore = DateTime.fromMillisecondsSinceEpoch(
    now.millisecondsSinceEpoch ~/ 1000 * 1000,
    isUtc: true,
  );
  final notAfter = notBefore.add(const Duration(days: 365 * 10));
  // As BoringSSL encodes adb's names: the country as PrintableString (its
  // type is fixed), the others as UTF8String (the default string mask).
  final name = Der.sequence([
    _rdn('2.5.4.6', Der.printableString('US')),
    _rdn('2.5.4.10', Der.utf8String('Android')),
    _rdn('2.5.4.3', Der.utf8String('Adb')),
  ]);
  final algorithm = Der.sequence([
    Der.objectIdentifier(sha256WithRsaOid),
    Der.nullValue(),
  ]);
  final keyIdentifier = hashes.sha1.convert(key.publicKeyPkcs1()).bytes;
  final extensions = Der.explicit(
    3,
    Der.sequence([
      _extension(
        '2.5.29.19',
        critical: true,
        value: Der.sequence([Der.boolean(true)]),
      ),
      _extension(
        '2.5.29.15',
        critical: true,
        // digitalSignature (bit 0), keyCertSign (5), cRLSign (6): one unused
        // trailing bit, so the bit string is 0x86 with 1 unused bit.
        value: Der.element(Der.tagBitString, const [0x01, 0x86]),
      ),
      _extension(
        '2.5.29.14',
        critical: false,
        value: Der.octetString(keyIdentifier),
      ),
    ]),
  );
  final tbs = Der.sequence([
    Der.explicit(0, Der.smallInteger(2)),
    Der.smallInteger(1),
    algorithm,
    name,
    Der.sequence([Der.time(notBefore), Der.time(notAfter)]),
    name,
    key.subjectPublicKeyInfo(),
    extensions,
  ]);
  final certificate = Der.sequence([
    tbs,
    algorithm,
    Der.bitString(key.signSha256(tbs)),
  ]);
  return TlsIdentity(certificateDer: certificate, key: key);
}

Uint8List _rdn(String oid, Uint8List value) => Der.set([
  Der.sequence([Der.objectIdentifier(oid), value]),
]);

Uint8List _extension(
  String oid, {
  required bool critical,
  required List<int> value,
}) => Der.sequence([
  Der.objectIdentifier(oid),
  if (critical) Der.boolean(true),
  Der.octetString(value),
]);
