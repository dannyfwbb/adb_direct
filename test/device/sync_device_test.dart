// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set (see test/device/README.md)'
    : null;

/// The only place these tests write: removed at the end.
const String scratch = '/data/local/tmp/adb_direct_test';

void main() {
  AdbConnection? connection;
  AdbConnection adb() => connection!;
  setUpAll(() async {
    if (skip != null) return;
    connection = await AdbConnection.connect(host!, port, key: AdbKeyPair.fromPem(File(keyPath!).readAsStringSync()));
    await adb().shell.run('rm -rf $scratch; mkdir -p $scratch');
  });
  tearDownAll(() async {
    final adb = connection;
    if (adb == null) return;
    await adb.shell.run('rm -rf $scratch');
    await adb.close();
  });

  test('stat a file, a directory, a missing path and a link', () async {
    final hosts = await adb().sync.stat('/system/etc/hosts');
    expect(hosts!.isFile, isTrue);
    expect(hosts.size, greaterThan(0));
    expect((await adb().sync.stat('/system'))!.isDirectory, isTrue);
    expect(await adb().sync.stat('/no/such/path'), isNull);
    final link = await adb().sync.stat('/sdcard');
    expect(link!.isLink, isTrue);
    if (!adb().sync.canFollowLinks) {
      // Before stat_v2 (Android 8) the device cannot follow it.
      await expectLater(adb().sync.stat('/sdcard', followLinks: true), throwsA(isA<AdbNotSupportedException>()));
      return;
    }
    final target = await adb().sync.stat('/sdcard', followLinks: true);
    printOnFailure('$link / $target');
    expect(target!.isDirectory, isTrue);
  }, skip: skip);

  test('list a directory', () async {
    final entries = await adb().sync.list('/system/etc');
    expect(entries.map((e) => e.name), contains('hosts'));
    expect(entries.map((e) => e.name), isNot(contains('.')));
  }, skip: skip);

  test(
    'round trips files of awkward sizes',
    () async {
      final random = Random(1);
      for (final size in [0, 1, 65535, 65536, 65537, 10 * 1024 * 1024 + 3]) {
        final bytes = Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
        final path = '$scratch/f$size';
        final modified = DateTime.utc(2024, 5, 6, 7, 8, 9);
        await adb().sync.writeAll(path, bytes, modified: modified);
        final stat = await adb().sync.stat(path);
        expect(stat!.size, size);
        expect(stat.modified, modified);
        // adbd copies the owner's bits to group and others: 0644 -> 0666.
        expect(stat.permissions, 0x1b6);
        final back = await adb().sync.readAll(path);
        expect(sha256.convert(back), sha256.convert(bytes), reason: '$size B');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a refused read is an AdbSyncException; the next call works', () async {
    // A missing file: refused for root too (old eng builds run adbd as root and can read anything).
    await expectLater(adb().sync.readAll('/no/such/file'), throwsA(isA<AdbSyncException>()));
    expect((await adb().sync.stat('/system/etc/hosts'))!.isFile, isTrue);
  }, skip: skip);

  test('a refused write is an AdbSyncException', () async {
    await expectLater(adb().sync.writeAll('/system/adb_direct_test', [1, 2, 3]), throwsA(isA<AdbSyncException>()));
    expect(await adb().sync.stat('/system/adb_direct_test'), isNull);
  }, skip: skip);

  test(
    'throughput',
    () async {
      final bytes = Uint8List(64 * 1024 * 1024);
      final path = '$scratch/big';
      var watch = Stopwatch()..start();
      await adb().sync.writeAll(path, bytes);
      final up = 64 / (watch.elapsedMilliseconds / 1000);
      watch = Stopwatch()..start();
      var total = 0;
      await for (final chunk in adb().sync.read(path)) {
        total += chunk.length;
      }
      final down = 64 / (watch.elapsedMilliseconds / 1000);
      print('sync push ${up.toStringAsFixed(1)} MiB/s, pull ${down.toStringAsFixed(1)} MiB/s');
      expect(total, bytes.length);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('pushes and pulls a directory tree; onlyChanged skips copies', () async {
    final local = await Directory.systemTemp.createTemp('adb_direct_tree');
    addTearDown(() => local.delete(recursive: true));
    File('${local.path}/a.txt').writeAsStringSync('alpha');
    Directory('${local.path}/sub/deeper').createSync(recursive: true);
    File('${local.path}/sub/b.bin').writeAsBytesSync(List.filled(70000, 3));
    File('${local.path}/sub/deeper/c').writeAsStringSync('');
    expect(await adb().sync.pushDirectory(local, '$scratch/tree'), 3);
    expect(await adb().sync.pushDirectory(local, '$scratch/tree', onlyChanged: true), 0);
    final back = await Directory.systemTemp.createTemp('adb_direct_back');
    addTearDown(() => back.delete(recursive: true));
    expect(await adb().sync.pullDirectory('$scratch/tree', back), 3);
    expect(File('${back.path}/a.txt').readAsStringSync(), 'alpha');
    expect(File('${back.path}/sub/b.bin').lengthSync(), 70000);
    expect(File('${back.path}/sub/deeper/c').lengthSync(), 0);
  }, skip: skip);

  test('pushFile and pullFile keep bytes and the modification time', () async {
    final dir = await Directory.systemTemp.createTemp('adb_direct_file');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/in.bin')..writeAsBytesSync(List.generate(300000, (i) => i * 7 % 251));
    await source.setLastModified(DateTime.utc(2022, 2, 2, 2, 2, 2));
    await adb().sync.pushFile(source, '$scratch/one.bin');
    final back = File('${dir.path}/out.bin');
    await adb().sync.pullFile('$scratch/one.bin', back);
    expect(back.readAsBytesSync(), source.readAsBytesSync());
    expect(back.lastModifiedSync().toUtc(), DateTime.utc(2022, 2, 2, 2, 2, 2));
  }, skip: skip);

  test(
    '200 MiB round trip, checked by SHA-256',
    () async {
      final random = Random(9);
      final block = Uint8List.fromList(List.generate(1 << 20, (_) => random.nextInt(256)));
      Stream<List<int>> source() async* {
        for (var i = 0; i < 200; i++) {
          yield block;
        }
      }

      final expected = await sha256.bind(source()).first;
      await adb().sync.write('$scratch/200', source(), size: 200 << 20);
      final actual = await sha256.bind(adb().sync.read('$scratch/200')).first;
      expect(actual, expected);
      await adb().shell.run('rm $scratch/200');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('sizes match the device; past 4 GiB with stat_v2', () async {
    final made = await adb().shell.run('truncate -s 5G $scratch/sparse && stat -c %s $scratch/sparse');
    if (made.exitCode != 0) {
      // Old devices have neither tool.
      await adb().shell.run('rm -f $scratch/sparse');
      markTestSkipped('no truncate or stat on this device');
      return;
    }
    final real = int.parse(made.stdoutText.trim());
    final stat = await adb().sync.stat('$scratch/sparse');
    await adb().shell.run('rm $scratch/sparse');
    expect(stat!.size, real);
    if (real <= 0xffffffff) {
      // The Android 14 TV emulator caps a sparse file at 1 GiB.
      markTestSkipped('this device cannot make a file past 4 GiB ($real B)');
    }
  }, skip: skip);
}
