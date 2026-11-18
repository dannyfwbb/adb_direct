// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The edwards25519 group (RFC 8032, section 5.1) as SPAKE2 needs it:
/// points from and to bytes, addition, negation, scalar multiplication,
/// and scalars reduced modulo the group order.
///
/// Field elements are 16 signed limbs of 16 bits (the layout TweetNaCl,
/// public domain, uses). Secret-dependent work has no secret-dependent
/// branches or indexes at source level: point selection uses masks, and
/// the scalar ladder always does the same steps. That is best effort in
/// Dart, whose integer representation may still vary in cost with values.
/// Decoding is variable time, as it only ever sees public points.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A field element modulo p = 2^255 - 19: 16 limbs, limb i weighs 2^(16 i).
typedef _Fe = Int64List;

_Fe _fe() => Int64List(16);

_Fe _copy(_Fe a) => Int64List.fromList(a);

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

_Fe _fromBigInt(BigInt n) {
  final o = _fe();
  var v = n % _p;
  for (var i = 0; i < 16; i++) {
    o[i] = (v & BigInt.from(0xffff)).toInt();
    v >>= 16;
  }
  return o;
}

BigInt _toBigInt(_Fe a) {
  final bytes = _pack(a);
  var n = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    n = (n << 8) | BigInt.from(bytes[i]);
  }
  return n;
}

/// d = -121665/121666.
final _Fe _d = _fromBigInt(-BigInt.from(121665) * BigInt.from(121666).modInverse(_p));
final _Fe _d2 = _add(_d, _d);

/// sqrt(-1) = 2^((p-1)/4).
final _Fe _sqrtM1 = _fromBigInt(BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p));

/// Propagates carries so every limb is back in 16 bits (the top limb's
/// overflow folds into limb 0 times 38, as 2^256 = 38 mod p).
void _carry(_Fe o) {
  for (var i = 0; i < 16; i++) {
    o[i] += 1 << 16;
    final c = o[i] >> 16;
    if (i < 15) {
      o[i + 1] += c - 1;
    } else {
      o[0] += 38 * (c - 1);
    }
    o[i] -= c << 16;
  }
}

/// Swaps [p] and [q] when [b] is 1, leaves them when it is 0, without a
/// branch on [b].
void _select(_Fe p, _Fe q, int b) {
  final mask = ~(b - 1);
  for (var i = 0; i < 16; i++) {
    final t = mask & (p[i] ^ q[i]);
    p[i] ^= t;
    q[i] ^= t;
  }
}

/// The canonical little-endian encoding (value below p).
Uint8List _pack(_Fe n) {
  final t = _copy(n);
  final m = _fe();
  _carry(t);
  _carry(t);
  _carry(t);
  for (var j = 0; j < 2; j++) {
    m[0] = t[0] - 0xffed;
    for (var i = 1; i < 15; i++) {
      m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
      m[i - 1] &= 0xffff;
    }
    m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
    final b = (m[15] >> 16) & 1;
    m[14] &= 0xffff;
    _select(t, m, 1 - b);
  }
  final o = Uint8List(32);
  for (var i = 0; i < 16; i++) {
    o[2 * i] = t[i] & 0xff;
    o[2 * i + 1] = t[i] >> 8;
  }
  return o;
}

/// 255 bits of [n] (the top bit is ignored); values from p to 2^255 - 1
/// are accepted and reduced, as BoringSSL does.
_Fe _unpack(List<int> n) {
  final o = _fe();
  for (var i = 0; i < 16; i++) {
    o[i] = n[2 * i] + (n[2 * i + 1] << 8);
  }
  o[15] &= 0x7fff;
  return o;
}

_Fe _add(_Fe a, _Fe b) {
  final o = _fe();
  for (var i = 0; i < 16; i++) {
    o[i] = a[i] + b[i];
  }
  return o;
}

_Fe _sub(_Fe a, _Fe b) {
  final o = _fe();
  for (var i = 0; i < 16; i++) {
    o[i] = a[i] - b[i];
  }
  return o;
}

_Fe _mul(_Fe a, _Fe b) {
  final t = Int64List(31);
  for (var i = 0; i < 16; i++) {
    final ai = a[i];
    for (var j = 0; j < 16; j++) {
      t[i + j] += ai * b[j];
    }
  }
  for (var i = 0; i < 15; i++) {
    t[i] += 38 * t[i + 16];
  }
  final o = Int64List.sublistView(t, 0, 16);
  final r = Int64List.fromList(o);
  _carry(r);
  _carry(r);
  return r;
}

_Fe _square(_Fe a) => _mul(a, a);

/// a^(p-2) = 1/a.
_Fe _invert(_Fe a) {
  var c = _copy(a);
  for (var i = 253; i >= 0; i--) {
    c = _square(c);
    if (i != 2 && i != 4) c = _mul(c, a);
  }
  return c;
}

/// a^((p-5)/8), for square roots.
_Fe _pow22523(_Fe a) {
  var c = _copy(a);
  for (var i = 250; i >= 0; i--) {
    c = _square(c);
    if (i != 1) c = _mul(c, a);
  }
  return c;
}

bool _isZero(_Fe a) => _pack(a).every((b) => b == 0);

/// The low bit of the canonical value: "negative" in RFC 8032's sense.
int _parity(_Fe a) => _pack(a)[0] & 1;

/// A point in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, xy = T/Z.
@internal
final class EdPoint {
  EdPoint._(this._x, this._y, this._z, this._t);

  /// The neutral element (0, 1).
  factory EdPoint.identity() => EdPoint._(_fe(), _fromBigInt(BigInt.one), _fromBigInt(BigInt.one), _fe());

  /// The base point B of RFC 8032 (y = 4/5, x even).
  static final EdPoint base = decode(_pack(_fromBigInt(BigInt.from(4) * BigInt.from(5).modInverse(_p))))!;

  final _Fe _x;
  final _Fe _y;
  final _Fe _z;
  final _Fe _t;

  /// Decodes 32 bytes as BoringSSL's `x25519_ge_frombytes_vartime` does:
  /// y from the low 255 bits (not required to be below p), x from the
  /// curve equation with the sign in the top bit. Null when no x exists.
  static EdPoint? decode(List<int> s) {
    if (s.length != 32) return null;
    final one = _fromBigInt(BigInt.one);
    final y = _unpack(s);
    final y2 = _square(y);
    final u = _sub(y2, one); // y² - 1
    final v = _add(_mul(y2, _d), one); // d y² + 1
    var x = _mul(_pow22523(_mul(u, v)), u); // u (u v)^((p-5)/8)
    final vxx = _mul(_square(x), v);
    if (!_isZero(_sub(vxx, u))) {
      if (!_isZero(_add(vxx, u))) return null;
      x = _mul(x, _sqrtM1);
    }
    if (_parity(x) != (s[31] >> 7)) x = _sub(_fe(), x);
    return EdPoint._(x, y, one, _mul(x, y));
  }

  /// The 32-byte encoding: canonical y, the sign of x in the top bit.
  Uint8List encode() {
    final zi = _invert(_z);
    final x = _mul(_x, zi);
    final y = _mul(_y, zi);
    final r = _pack(y);
    r[31] ^= _parity(x) << 7;
    return r;
  }

  /// this + [q] (the complete twisted Edwards formula, also for doubling).
  EdPoint operator +(EdPoint q) {
    final a = _mul(_sub(_y, _x), _sub(q._y, q._x));
    final b = _mul(_add(_x, _y), _add(q._x, q._y));
    final c = _mul(_mul(_t, q._t), _d2);
    var d = _mul(_z, q._z);
    d = _add(d, d);
    final e = _sub(b, a);
    final f = _sub(d, c);
    final g = _add(d, c);
    final h = _add(b, a);
    return EdPoint._(_mul(e, f), _mul(h, g), _mul(g, f), _mul(e, h));
  }

  EdPoint operator -() => EdPoint._(_sub(_fe(), _x), _y, _z, _sub(_fe(), _t));

  EdPoint operator -(EdPoint q) => this + -q;

  /// [scalar] (32 bytes, little-endian, all 256 bits used) times this
  /// point, by a ladder that does the same work for every scalar.
  EdPoint multiply(List<int> scalar) {
    if (scalar.length != 32) {
      throw ArgumentError.value(scalar.length, 'scalar', 'must be 32 bytes');
    }
    var p = EdPoint.identity();
    // A copy: the masked swaps work in place and must not touch this point
    // (the base point and SPAKE2's M and N are shared).
    var q = EdPoint._(_copy(_x), _copy(_y), _copy(_z), _copy(_t));
    for (var i = 255; i >= 0; i--) {
      final bit = (scalar[i >> 3] >> (i & 7)) & 1;
      _swap(p, q, bit);
      q = q + p;
      p = p + p;
      _swap(p, q, bit);
    }
    return p;
  }

  static void _swap(EdPoint p, EdPoint q, int bit) {
    _select(p._x, q._x, bit);
    _select(p._y, q._y, bit);
    _select(p._z, q._z, bit);
    _select(p._t, q._t, bit);
  }

  /// Whether two points are the same group element.
  bool equals(EdPoint other) {
    final a = encode();
    final b = other.encode();
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// The order l of the prime-order subgroup, little-endian.
const List<int> _l = [
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, //
  0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0x10,
];

/// The group order l as bytes.
@internal
Uint8List get groupOrder => Uint8List.fromList(_l);

/// [x] (64 bytes, little-endian) modulo l, as 32 bytes: the same result
/// as BoringSSL's `x25519_sc_reduce`, computed as TweetNaCl's `modL` does.
@internal
Uint8List reduceScalar(List<int> x) {
  if (x.length != 64) {
    throw ArgumentError.value(x.length, 'x', 'must be 64 bytes');
  }
  final t = Int64List(65)..setRange(0, 64, x);
  for (var i = 63; i >= 32; i--) {
    var carry = 0;
    var j = i - 32;
    for (; j < i - 12; j++) {
      t[j] += carry - 16 * t[i] * _l[j - (i - 32)];
      carry = (t[j] + 128) >> 8;
      t[j] -= carry << 8;
    }
    t[j] += carry;
    t[i] = 0;
  }
  var carry = 0;
  for (var j = 0; j < 32; j++) {
    t[j] += carry - (t[31] >> 4) * _l[j];
    carry = t[j] >> 8;
    t[j] &= 255;
  }
  for (var j = 0; j < 32; j++) {
    t[j] -= carry * _l[j];
  }
  final r = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    t[i + 1] += t[i] >> 8;
    r[i] = t[i] & 255;
  }
  return r;
}

/// Exposed for tests: a field element through BigInt and back.
@visibleForTesting
BigInt fieldRoundTrip(BigInt n) => _toBigInt(_fromBigInt(n));

/// Exposed for tests: a × b mod p through the limb arithmetic.
@visibleForTesting
BigInt fieldMultiply(BigInt a, BigInt b) => _toBigInt(_mul(_fromBigInt(a), _fromBigInt(b)));

/// Exposed for tests: 1/a mod p through the limb arithmetic.
@visibleForTesting
BigInt fieldInvert(BigInt a) => _toBigInt(_invert(_fromBigInt(a)));

/// Exposed for tests: a - b mod p through the limb arithmetic.
@visibleForTesting
BigInt fieldSubtract(BigInt a, BigInt b) => _toBigInt(_sub(_fromBigInt(a), _fromBigInt(b)));
