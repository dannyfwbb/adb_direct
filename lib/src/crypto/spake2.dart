// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../bytes.dart';
import 'ed25519.dart';

/// The two sides of SPAKE2. The pairing client is [alice].
@internal
enum Spake2Role { alice, bob }

/// SPAKE2 over edwards25519, byte for byte as BoringSSL's `SPAKE2_*` (`crypto/curve25519/spake25519.cc`), which adbd
/// uses for pairing.
///
/// It differs from the IETF draft in three ways that matter for compatibility: the password is hashed with SHA-512 and
/// reduced modulo the group order; multiples of the order are added to that scalar so its low three bits are zero
/// (BoringSSL's "password scalar hack"); and the key is SHA-512 over length-prefixed names, messages, the shared point
/// and the full password hash.
@internal
final class Spake2 {
  /// A context for [role]; [myName] and [theirName] are the identities both sides agree on (adb: `adb pair client\0`,
  /// `adb pair server\0`). [random] supplies the 64 secret bytes (tests pass fixed ones).
  Spake2(this.role, {required List<int> myName, required List<int> theirName, Uint8List Function(int length)? random})
    : _myName = Uint8List.fromList(myName),
      _theirName = Uint8List.fromList(theirName),
      _random = random ?? randomBytes;

  /// The side this context plays.
  final Spake2Role role;

  final Uint8List _myName;
  final Uint8List _theirName;
  final Uint8List Function(int length) _random;

  Uint8List? _privateKey;
  Uint8List? _myMessage;
  Uint8List? _passwordScalar;
  Uint8List? _passwordHash;
  bool _done = false;

  /// M (Alice's mask) and N (Bob's): fixed points from BoringSSL, the first entries of its `kSpakeMSmallPrecomp` and
  /// `kSpakeNSmallPrecomp` tables.
  static final EdPoint _m = EdPoint.decode(
    hexDecode('5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e'),
  )!;
  static final EdPoint _n = EdPoint.decode(
    hexDecode('10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778'),
  )!;

  EdPoint get _myMask => role == Spake2Role.alice ? _m : _n;
  EdPoint get _theirMask => role == Spake2Role.alice ? _n : _m;

  /// The 32-byte message for the other side, from [password]. Once only.
  Uint8List generateMessage(List<int> password) {
    if (_myMessage != null) {
      throw StateError('A SPAKE2 context generates one message only');
    }
    // A secret scalar, times eight so the peer's small-order component vanishes later.
    final privateKey = _shiftLeft3(reduceScalar(_random(64)));

    final hash = Uint8List.fromList(sha512.convert(password).bytes);
    final passwordScalar = _withoutLowBits(reduceScalar(hash));

    final message = (EdPoint.base.multiply(privateKey) + _myMask.multiply(passwordScalar)).encode();
    _privateKey = privateKey;
    _passwordHash = hash;
    _passwordScalar = passwordScalar;
    return _myMessage = message;
  }

  /// The 64-byte shared key from the other side's message. Both sides get the same key only when they used the same
  /// password. Throws [FormatException] when [theirMessage] is not a point.
  Uint8List processMessage(List<int> theirMessage) {
    final myMessage = _myMessage;
    if (myMessage == null || _done) {
      throw StateError('Generate a message first, and process one only');
    }
    final q = theirMessage.length == 32 ? EdPoint.decode(theirMessage) : null;
    if (q == null) {
      throw const FormatException('The SPAKE2 message is not a curve point');
    }
    final shared = (q - _theirMask.multiply(_passwordScalar!)).multiply(_privateKey!).encode();

    final transcript = BytesBuilder(copy: false);
    void add(List<int> data) {
      final length = ByteData(8)..setUint64(0, data.length, Endian.little);
      transcript
        ..add(length.buffer.asUint8List())
        ..add(data);
    }

    if (role == Spake2Role.alice) {
      add(_myName);
      add(_theirName);
      add(myMessage);
      add(theirMessage);
    } else {
      add(_theirName);
      add(_myName);
      add(theirMessage);
      add(myMessage);
    }
    add(shared);
    add(_passwordHash!);
    _done = true;
    return Uint8List.fromList(sha512.convert(transcript.takeBytes()).bytes);
  }

  /// n × 8 for a 32-byte little-endian n below 2^253.
  static Uint8List _shiftLeft3(Uint8List n) {
    final o = Uint8List(32);
    var carry = 0;
    for (var i = 0; i < 32; i++) {
      o[i] = ((n[i] << 3) | carry) & 0xff;
      carry = n[i] >> 5;
    }
    return o;
  }

  /// BoringSSL's password scalar hack: adds l, 2l and 4l as the low three bits require, so the result is a multiple of
  /// eight that names the same point in the prime-order subgroup. Masks, no branches.
  static Uint8List _withoutLowBits(Uint8List scalar) {
    final s = Uint8List.fromList(scalar);
    var order = groupOrder;
    for (var shift = 0; shift < 3; shift++) {
      // 0xff when bit [shift] is set, else 0.
      final mask = -((s[0] >> shift) & 1) & 0xff;
      var carry = 0;
      for (var i = 0; i < 32; i++) {
        final sum = s[i] + (order[i] & mask) + carry;
        s[i] = sum & 0xff;
        carry = sum >> 8;
      }
      order = _double(order);
    }
    return s;
  }

  static Uint8List _double(Uint8List n) {
    final o = Uint8List(32);
    var carry = 0;
    for (var i = 0; i < 32; i++) {
      final v = (n[i] << 1) | carry;
      o[i] = v & 0xff;
      carry = v >> 8;
    }
    return o;
  }
}
