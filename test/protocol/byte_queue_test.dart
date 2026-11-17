// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:adb_direct/src/protocol/byte_queue.dart';
import 'package:test/test.dart';

void main() {
  group('ByteQueue', () {
    test('takes across chunk boundaries in arbitrary sizes', () {
      final queue = ByteQueue()
        ..add([1, 2, 3])
        ..add([4])
        ..add([5, 6, 7, 8, 9]);
      expect(queue.length, 9);
      expect(queue.take(2), [1, 2]);
      expect(queue.take(4), [3, 4, 5, 6]);
      expect(queue.length, 3);
      expect(queue.take(3), [7, 8, 9]);
      expect(queue.isEmpty, isTrue);
    });

    test('peeks without consuming', () {
      final queue = ByteQueue()
        ..add([0x78, 0x56])
        ..add([0x34, 0x12, 0xff]);
      expect(queue.peekUint32Le(0), 0x12345678);
      expect(queue.byteAt(4), 0xff);
      expect(queue.length, 5);
    });

    test('reads a full 32-bit value without sign problems', () {
      final queue = ByteQueue()..add([0xff, 0xff, 0xff, 0xff]);
      expect(queue.peekUint32Le(0), 0xffffffff);
    });

    test('a take inside one chunk is a view, not a copy', () {
      final chunk = Uint8List.fromList([1, 2, 3, 4]);
      final queue = ByteQueue()..add(chunk);
      final taken = queue.take(2);
      chunk[0] = 9;
      expect(taken[0], 9);
    });

    test('skip and clear', () {
      final queue = ByteQueue()
        ..add([1, 2, 3])
        ..add([4, 5]);
      queue.skip(4);
      expect(queue.take(1), [5]);
      queue
        ..add([6])
        ..clear();
      expect(queue.length, 0);
    });

    test('ignores empty chunks and accepts plain lists', () {
      final queue = ByteQueue()
        ..add(const [])
        ..add(<int>[7, 8]);
      expect(queue.take(2), [7, 8]);
    });

    test('rejects out-of-range requests', () {
      final queue = ByteQueue()..add([1, 2]);
      expect(() => queue.take(3), throwsRangeError);
      expect(() => queue.byteAt(2), throwsRangeError);
      expect(() => queue.skip(-1), throwsRangeError);
    });
  });
}
