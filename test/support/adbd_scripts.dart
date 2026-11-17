// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/src/crypto/adb_key_pair.dart';
import 'package:adb_direct/src/crypto/adb_public_key.dart';
import 'package:adb_direct/src/crypto/der.dart';
import 'package:adb_direct/src/crypto/rsa.dart';
import 'package:adb_direct/src/protocol/banner.dart';
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';

import 'fake_adbd.dart';
import 'fixtures.dart';

/// The test-only key pair (`test/fixtures/keys/adbkey`).
final AdbKeyPair testKey = AdbKeyPair.fromPem(
  File('test/fixtures/keys/adbkey').readAsStringSync(),
  comment: 'test@adb_direct',
);

/// A second key the fake devices do not trust.
final AdbKeyPair otherKey = AdbKeyPair.fromPem(
  File('test/fixtures/keys/adbkey_other').readAsStringSync(),
  comment: 'other@adb_direct',
);

/// The banner the Google TV emulator (Android 14) sent on 2026-11-17.
final Uint8List tvBanner = Fixture.load(
  'handshake/trusted_key',
).fromDevice.last.payload;

/// A banner like [tvBanner] without `delayed_ack`.
final Uint8List classicBanner = utf8.encode(
  'device::ro.product.name=p;ro.product.model=Classic;ro.product.device=d;'
  'features=shell_v2,cmd,stat_v2,ls_v2',
);

/// A banner of a device without shell protocol v2 (Android 6 and older).
final Uint8List oldBanner = utf8.encode(
  'device::ro.product.name=p;ro.product.model=Old;ro.product.device=d;',
);

/// Whether [signature] is [publicKey]'s PKCS#1 v1.5 SHA-1 signature of
/// [token], checked the way adbd does (`RSA_verify(NID_sha1, token, …)`).
bool verifyTokenSignature(
  AdbPublicKey publicKey,
  List<int> token,
  List<int> signature,
) {
  final s = Der.unsignedValue(signature);
  final m = s.modPow(publicKey.exponent, publicKey.modulus);
  final em = Der.unsignedBytes(m, length: 256);
  final expected = Uint8List(256)
    ..[1] = 1
    ..fillRange(2, 256 - 36, 0xff)
    ..setRange(256 - 35, 256 - 20, sha1DigestInfoPrefix)
    ..setRange(256 - 20, 256, token);
  for (var i = 0; i < 256; i++) {
    if (em[i] != expected[i]) return false;
  }
  return true;
}

/// Plays adbd's side of the handshake: expects our `CNXN`, challenges with a
/// token, verifies the signature against [trusted], then answers with
/// [banner]. Returns the client's `CNXN`.
Future<AdbMessage> acceptHandshake(
  FakeAdbdSession session, {
  List<AdbPublicKey>? trusted,
  Uint8List? banner,
  int version = AdbProtocol.version,
  int maxPayload = AdbProtocol.maxPayload,
}) async {
  final keys = trusted ?? [testKey.publicKey];
  final cnxn = await session.receive();
  if (cnxn.command != AdbCommand.connect) {
    throw FakeAdbdFailure('expected CNXN, got $cnxn');
  }
  while (true) {
    final token = randomToken();
    session.send(AdbMessage.auth(AdbAuthType.token, token));
    final answer = await session.receive();
    if (answer.command != AdbCommand.auth ||
        answer.arg0 != AdbAuthType.signature.value) {
      throw FakeAdbdFailure('expected a signature, got $answer');
    }
    if (keys.any((k) => verifyTokenSignature(k, token, answer.payload))) {
      break;
    }
  }
  session
    ..send(
      AdbMessage(AdbCommand.connect, version, maxPayload, banner ?? tvBanner),
    )
    ..withChecksum = version < AdbProtocol.versionSkipChecksum;
  return cnxn;
}

/// A fresh random 20-byte token.
Uint8List randomToken() {
  final random = Random.secure();
  return Uint8List.fromList(
    List.generate(AdbProtocol.authTokenLength, (_) => random.nextInt(256)),
  );
}

/// The host banner a client sent in [cnxn].
AdbBanner hostBanner(AdbMessage cnxn) => AdbBanner.parse(cnxn.payload);
