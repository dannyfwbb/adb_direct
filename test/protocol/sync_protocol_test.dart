// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:adb_direct/src/protocol/sync_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('errno names: the common ones by name, the rest by number', () {
    for (final (errno, name) in const [
      (1, 'EPERM'),
      (2, 'ENOENT'),
      (5, 'EIO'),
      (13, 'EACCES'),
      (17, 'EEXIST'),
      (20, 'ENOTDIR'),
      (21, 'EISDIR'),
      (28, 'ENOSPC'),
      (30, 'EROFS'),
      (36, 'ENAMETOOLONG'),
      (40, 'ELOOP'),
    ]) {
      expect(errnoName(errno), startsWith(name));
    }
    expect(errnoName(999), 'errno 999');
  });

  test('a path longer than the limit is refused before anything is sent', () {
    final longest = 'a' * SyncLimits.maxPath;
    expect(SyncRequest.withPath(SyncId.stat, longest), hasLength(8 + SyncLimits.maxPath));
    expect(() => SyncRequest.withPath(SyncId.stat, '${longest}a'), throwsArgumentError);
    // The limit is in bytes, not characters.
    expect(() => SyncRequest.withPath(SyncId.stat, 'é' * (SyncLimits.maxPath ~/ 2 + 1)), throwsArgumentError);
  });
}
