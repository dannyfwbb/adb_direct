// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_direct/src/crypto/spake2.dart';
import 'package:test/test.dart';

import '../support/hex.dart';

/// Vectors from BoringSSL's SPAKE2_generate_msg and SPAKE2_process_msg,
/// built with FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION (RAND_bytes is
/// deterministic there): both sides draw [random] as their 64 secret
/// bytes; names "client" (Alice) and "server" (Bob). The passwords cover
/// the password scalar corrections 0, 1, 2, 3, 6 and 7.
const random =
    '7d92cd33b7935bd9ef77d7700ddb4c0972ac611476559829d158d74b0bb7326c'
    '3e48e572d81eaedc13452d6ec225ce223f69608668f925ae4e71e7fa12e92728';

const vectors = [
  (
    '123456',
    'dd8e07cf8376f67c1fd08a36fb6c283c8b490dbd9eb4d98e29451329cf255293',
    'd926fa936ec640a0a8e36730fb334cf9618dbfa262e55d24a643ef3f84d96711',
    '02ca73193e7094f957ea155be67b5d7c1c9bf6e7f365b9bb90034a27b51ce85e'
        '0052ad9ca667740fb17e2cccfce8bbe07eb9369a27e61edbad5d75a6b376c488',
  ),
  (
    '555555',
    'cdddb4221c18df213084f7eb701c06ebdb1c51369bd9f015d681113ac8961662',
    '32ccd6f4bbc9c43ae7934b9bd42e8a648006c3b387585f1896560ad52e64a0bf',
    '94dc4a9bca499d0c69cac3fc37a34efadba7a61b1aba124d47ed2957e8861fee'
        '440c5d5a096c0d25e18b83ac28b69b9ebed9cedf428f8afdc112b2634d33cb73',
  ),
  (
    '111111',
    '0cc4c8c8cb258ee08d86927bf24ebd34a0e0e9778ed3255b139df26fce3795d3',
    '7994682412fe882d2e0952bb97473c279eff7d4db6d06a23f354124022d5123c',
    '624ae01fcfb53e1b094c1846e8e3c35a4826795281d116eba9bcc440716cb0c7'
        '082023918e4b72136d2132c9c1939b11402f6e3b5ab1d89fe70b6035cb4c1970',
  ),
  (
    '424242',
    '4441958eed123e842f3ebd268ba572e01d68e64ab31db9dda0e82e867ff40020',
    'f0a1f18abb70d9d058c2ef89597ee3d19cd27778c88074ecc9b70ef866a62444',
    'a25f52e1b20fe471f007593e16ab042b6df0e7670061fefa41828843da879ca2'
        '2480ed6f8375fc7006efb6cc79e776c1ad3cf93bcb83663f95c44a2439441d22',
  ),
  (
    '222222',
    '9dddfc2d0cb5060935604c16386ee6412b498b4d81acad67174c3954d2a07d4a',
    '21444d5f807dce6c4507d83b907f7cdb4ff492e8f7d5bea66be01da2f60fc6bd',
    'ba407d1a5a136b9115a4f81dd2e9730e1fabce1ac51e8f60248cdd55b982a851'
        '5316372bf3c6c6ab18c456ee087310a2e0bcf10402361def0cd2d22db79ec110',
  ),
  (
    '333333',
    '8e3bb6ce31c5cc782080940a9f0bbda3cbb7db4b230249da12f56f56ea99bdff',
    'd975bb8befee13d5d37e54026196275b3c110085c79835845877ea8273335952',
    '5ea7a3afcf1d28e46d3fda3194ad96b09d335cefcdc8bbe3807b6b790e454294'
        '3064f801875bed0104f3e42683b5f6b6e6c64f94d3c66c79389c3c5549188063',
  ),
];

Spake2 fixed(Spake2Role role) => Spake2(
  role,
  myName: utf8.encode(role == Spake2Role.alice ? 'client' : 'server'),
  theirName: utf8.encode(role == Spake2Role.alice ? 'server' : 'client'),
  random: (n) => unhex(random).sublist(0, n),
);

Spake2 adb(Spake2Role role) => Spake2(
  role,
  myName: utf8.encode(role == Spake2Role.alice ? 'adb pair client\u0000' : 'adb pair server\u0000'),
  theirName: utf8.encode(role == Spake2Role.alice ? 'adb pair server\u0000' : 'adb pair client\u0000'),
);

void main() {
  test('Alice matches BoringSSL byte for byte', () {
    for (final (password, alice, bob, key) in vectors) {
      final ctx = fixed(Spake2Role.alice);
      expect(hex(ctx.generateMessage(utf8.encode(password))), alice, reason: password);
      expect(hex(ctx.processMessage(unhex(bob))), key, reason: password);
    }
  });

  test('Bob matches BoringSSL byte for byte', () {
    for (final (password, alice, bob, key) in vectors) {
      final ctx = fixed(Spake2Role.bob);
      expect(hex(ctx.generateMessage(utf8.encode(password))), bob, reason: password);
      expect(hex(ctx.processMessage(unhex(alice))), key, reason: password);
    }
  });

  test('random contexts with adb names agree; a wrong code does not', () {
    final password = utf8.encode('987654');
    final alice = adb(Spake2Role.alice);
    final bob = adb(Spake2Role.bob);
    final a = alice.generateMessage(password);
    final b = bob.generateMessage(password);
    expect(alice.processMessage(b), bob.processMessage(a));

    final alice2 = adb(Spake2Role.alice);
    final bob2 = adb(Spake2Role.bob);
    final a2 = alice2.generateMessage(password);
    final b2 = bob2.generateMessage(utf8.encode('987655'));
    expect(alice2.processMessage(b2), isNot(bob2.processMessage(a2)));
  });

  test('a message that is not a point, or of the wrong size', () {
    final ctx = adb(Spake2Role.alice)..generateMessage([1]);
    expect(() => ctx.processMessage(Uint8List(32)..[0] = 2), throwsFormatException);
    expect(() => ctx.processMessage(Uint8List(31)), throwsFormatException);
  });

  test('one message, one key', () {
    final ctx = adb(Spake2Role.alice);
    expect(() => ctx.processMessage(Uint8List(32)), throwsStateError);
    ctx.generateMessage([1]);
    expect(() => ctx.generateMessage([1]), throwsStateError);
    final other = adb(Spake2Role.bob);
    final key = ctx.processMessage(other.generateMessage([1]));
    expect(key, hasLength(64));
    expect(() => ctx.processMessage(Uint8List(32)), throwsStateError);
  });
}
