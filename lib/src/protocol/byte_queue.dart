// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:collection';
import 'dart:typed_data';

/// A FIFO of bytes that arrive in chunks and leave in arbitrary sizes.
///
/// Chunks are kept as they came; nothing is copied until bytes are taken, and
/// a take that falls inside one chunk returns a view of it. Used by every
/// framing layer (messages, shell protocol, sync) so each one parses from a
/// single, tested buffer.
final class ByteQueue {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _headOffset = 0;
  int _length = 0;

  /// Number of bytes buffered.
  int get length => _length;

  /// Whether no bytes are buffered.
  bool get isEmpty => _length == 0;

  /// Appends [bytes]. The queue keeps a reference: callers must not modify
  /// the list afterwards.
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _chunks.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _length += bytes.length;
  }

  /// The byte at [index] counted from the front, without consuming it.
  int byteAt(int index) {
    RangeError.checkValueInInterval(index, 0, _length - 1, 'index');
    var remaining = index + _headOffset;
    for (final chunk in _chunks) {
      if (remaining < chunk.length) return chunk[remaining];
      remaining -= chunk.length;
    }
    throw StateError('unreachable');
  }

  /// The little-endian unsigned 32-bit integer at [offset], not consumed.
  int peekUint32Le(int offset) =>
      byteAt(offset) | (byteAt(offset + 1) << 8) | (byteAt(offset + 2) << 16) | (byteAt(offset + 3) << 24);

  /// Removes and returns the first [count] bytes.
  ///
  /// The result may be a view of a buffered chunk; treat it as read-only.
  Uint8List take(int count) {
    RangeError.checkValueInInterval(count, 0, _length, 'count');
    if (count == 0) return Uint8List(0);
    final head = _chunks.first;
    final available = head.length - _headOffset;
    if (count <= available) {
      final view = Uint8List.sublistView(head, _headOffset, _headOffset + count);
      _consume(count);
      return view;
    }
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      final chunk = _chunks.first;
      final n = (chunk.length - _headOffset).clamp(0, count - written);
      out.setRange(written, written + n, chunk, _headOffset);
      written += n;
      _consume(n);
    }
    return out;
  }

  /// Discards the first [count] bytes.
  void skip(int count) {
    RangeError.checkValueInInterval(count, 0, _length, 'count');
    _consume(count);
  }

  /// Removes everything.
  void clear() {
    _chunks.clear();
    _headOffset = 0;
    _length = 0;
  }

  void _consume(int count) {
    var remaining = count;
    _length -= count;
    while (remaining > 0) {
      final available = _chunks.first.length - _headOffset;
      if (remaining < available) {
        _headOffset += remaining;
        return;
      }
      remaining -= available;
      _chunks.removeFirst();
      _headOffset = 0;
    }
  }
}
