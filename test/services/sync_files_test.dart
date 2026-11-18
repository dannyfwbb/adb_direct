// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/tree_device.dart';

/// Android 7-9: shell protocol v2 without `fixed_push_mkdir`.
final List<int> android8 = utf8.encode('device::ro.product.model=N;features=shell_v2,cmd,stat_v2');

/// A later device: it makes the parents of a pushed file itself.
final List<int> android11 = utf8.encode('device::ro.product.model=R;features=shell_v2,cmd,stat_v2,fixed_push_mkdir');

/// A local tree: `a/b/f`, `a/empty/`, `a/only_pipe/<fifo>`, `top`, `link -> top`.
Directory tree() {
  final dir = Directory.systemTemp.createTempSync('tree');
  addTearDown(() => dir.deleteSync(recursive: true));
  Directory('${dir.path}/a/b').createSync(recursive: true);
  Directory('${dir.path}/a/empty').createSync();
  Directory('${dir.path}/a/only_pipe').createSync();
  File('${dir.path}/a/b/f').writeAsStringSync('x');
  File('${dir.path}/top').writeAsStringSync('yy');
  Link('${dir.path}/link').createSync('top');
  final fifo = Process.runSync('mkfifo', ['${dir.path}/a/only_pipe/pipe']);
  if (fifo.exitCode != 0) fail('mkfifo failed: ${fifo.stderr}');
  return dir;
}

Future<(AdbConnection, FakeAdbd)> connect(List<int> banner, TreeDevice device) async {
  final adbd = await FakeAdbd.start((session) async {
    await acceptHandshake(session, banner: Uint8List.fromList(banner));
    await device.serve(session);
  });
  return (await AdbConnection.connect(adbd.address, adbd.port, key: testKey), adbd);
}

void main() {
  test('Android 7-9: the whole tree is made first, then files and links; pipes are skipped', () async {
    final dir = tree();
    final device = TreeDevice();
    final (adb, adbd) = await connect(android8, device);
    expect(await adb.sync.pushDirectory(dir, '/t'), 3);
    expect(device.log.first, 'shell mkdir -p /t /t/a /t/a/b /t/a/empty /t/a/only_pipe');
    expect(device.log.skip(1).map((l) => l.split(' ').take(2).join(' ')), {
      'push /t/a/b/f',
      'push /t/top',
      'push /t/link',
    });
    expect(device.log, contains('push /t/link 120777'));
    expect(device.log, hasLength(4));
    expect(utf8.decode(device.files['/t/link']!), 'top');
    expect(utf8.decode(device.files['/t/top']!), 'yy');
    await adb.close();
    await adbd.done();
  }, testOn: '!windows');

  test('later devices: only empty directories (one holding just a pipe counts) are made', () async {
    final dir = tree();
    final device = TreeDevice();
    final (adb, adbd) = await connect(android11, device);
    expect(await adb.sync.pushDirectory(dir, '/t/'), 3);
    expect(device.log.first, 'shell mkdir -p /t/a/empty /t/a/only_pipe');
    expect(device.log.where((l) => l.startsWith('push')), hasLength(3));
    await adb.close();
    await adbd.done();
  }, testOn: '!windows');

  test('an empty local directory makes the remote one; nothing to make, no shell', () async {
    final empty = Directory.systemTemp.createTempSync('empty');
    addTearDown(() => empty.deleteSync(recursive: true));
    final device = TreeDevice();
    final (adb, adbd) = await connect(android11, device);
    expect(await adb.sync.pushDirectory(empty, '/e'), 0);
    expect(device.log, ['shell mkdir -p /e']);

    File('${empty.path}/f').writeAsStringSync('1');
    device.log.clear();
    expect(await adb.sync.pushDirectory(empty, '/e'), 1);
    expect(device.log.single, startsWith('push /e/f '));
    await adb.close();
    await adbd.done();
  });

  test('a directory the device cannot make is an AdbSyncException, before any file', () async {
    final dir = tree();
    final device = TreeDevice(shellExit: (_) => 1);
    final (adb, adbd) = await connect(android8, device);
    await expectLater(
      adb.sync.pushDirectory(dir, '/t'),
      throwsA(isA<AdbSyncException>().having((e) => e.path, 'path', '/t')),
    );
    expect(device.log, hasLength(1));
    await adb.close();
    await adbd.done();
  }, testOn: '!windows');
}
