// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// XXH32, the checksum of the LZ4 frame format, written from the xxHash specification (`doc/xxhash_spec.md` in the
/// xxHash repository). Fed in pieces with [add]; [digest] gives the hash of everything added so far.
final class Xxh32 {
  /// Starts a hash with a seed (0 in LZ4 frames).
  Xxh32([this._seed = 0]) {
    _v1 = _add(_add(_seed, _prime1), _prime2);
    _v2 = _add(_seed, _prime2);
    _v3 = _seed;
    _v4 = (_seed - _prime1) & _mask;
  }

  /// The hash of [bytes] in one go.
  static int of(List<int> bytes, [int seed = 0]) => (Xxh32(seed)..add(bytes)).digest();

  static const int _mask = 0xffffffff;
  static const int _prime1 = 0x9e3779b1;
  static const int _prime2 = 0x85ebca77;
  static const int _prime3 = 0xc2b2ae3d;
  static const int _prime4 = 0x27d4eb2f;
  static const int _prime5 = 0x165667b1;

  final int _seed;
  late int _v1;
  late int _v2;
  late int _v3;
  late int _v4;
  int _total = 0;

  /// Bytes not yet forming a whole 16-byte stripe.
  final Uint8List _pending = Uint8List(16);
  int _pendingLength = 0;

  /// Adds [bytes] (or the part from [start] to [end]) to the hash.
  void add(List<int> bytes, [int start = 0, int? end]) {
    final stop = end ?? bytes.length;
    _total += stop - start;
    var i = start;
    if (_pendingLength > 0) {
      while (_pendingLength < 16 && i < stop) {
        _pending[_pendingLength++] = bytes[i++];
      }
      if (_pendingLength < 16) return;
      _stripe(_pending, 0);
      _pendingLength = 0;
    }
    while (i + 16 <= stop) {
      _stripe(bytes, i);
      i += 16;
    }
    while (i < stop) {
      _pending[_pendingLength++] = bytes[i++];
    }
  }

  /// The hash of everything added so far. More can be added afterwards.
  int digest() {
    var acc = _total >= 16
        ? _add(_add(_rotl(_v1, 1), _rotl(_v2, 7)), _add(_rotl(_v3, 12), _rotl(_v4, 18)))
        : _add(_seed, _prime5);
    acc = _add(acc, _total & _mask);
    var i = 0;
    for (; i + 4 <= _pendingLength; i += 4) {
      acc = _mul(_rotl(_add(acc, _mul(_le32(_pending, i), _prime3)), 17), _prime4);
    }
    for (; i < _pendingLength; i++) {
      acc = _mul(_rotl(_add(acc, _mul(_pending[i], _prime5)), 11), _prime1);
    }
    acc ^= acc >>> 15;
    acc = _mul(acc, _prime2);
    acc ^= acc >>> 13;
    acc = _mul(acc, _prime3);
    acc ^= acc >>> 16;
    return acc;
  }

  void _stripe(List<int> bytes, int offset) {
    _v1 = _round(_v1, _le32(bytes, offset));
    _v2 = _round(_v2, _le32(bytes, offset + 4));
    _v3 = _round(_v3, _le32(bytes, offset + 8));
    _v4 = _round(_v4, _le32(bytes, offset + 12));
  }

  static int _round(int acc, int lane) => _mul(_rotl(_add(acc, _mul(lane, _prime2)), 13), _prime1);

  static int _le32(List<int> bytes, int offset) =>
      bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16 | bytes[offset + 3] << 24;

  static int _add(int a, int b) => (a + b) & _mask;

  /// The low 32 bits of [a] × [b], without products past 2^53 (so the result is the same where ints are doubles).
  static int _mul(int a, int b) => ((a * (b & 0xffff)) + (((a * (b >>> 16)) & 0xffff) << 16)) & _mask;

  static int _rotl(int x, int bits) => ((x << bits) | (x >>> (32 - bits))) & _mask;
}
