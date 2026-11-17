// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';

void main() {
  test('Android 7-9 (shell v2, no fixed_push_mkdir): the tree is made '
      'with mkdir before the files', () async {
    final dir = Directory.systemTemp.createTempSync('tree');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/a/b').createSync(recursive: true);
    File('${dir.path}/a/b/f').writeAsStringSync('x');

    final opened = <String>[];
    final adbd = await FakeAdbd.start((session) async {
      await acceptHandshake(
        session,
        banner: utf8.encode(
          'device::ro.product.model=N;features=shell_v2,cmd,stat_v2',
        ),
      );
      // Only the first OPEN matters here; the sync session that follows
      // is refused, which ends the push with an error.
      final open = await session.receive();
      opened.add(utf8.decode(open.payload).replaceAll('\u0000', ''));
      session.send(AdbMessage.close(localId: 0, remoteId: open.arg0));
      final next = await session.receive();
      opened.add(utf8.decode(next.payload).replaceAll('\u0000', ''));
      session.send(AdbMessage.close(localId: 0, remoteId: next.arg0));
      await session.expectClientClose().catchError((Object _) {});
    });
    final adb = await AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: testKey,
    );
    await expectLater(
      adb.sync.pushDirectory(dir, '/data/local/tmp/t'),
      throwsA(isA<AdbException>()),
    );
    expect(
      opened.first,
      'shell,v2,raw:mkdir -p /data/local/tmp/t /data/local/tmp/t/a '
      '/data/local/tmp/t/a/b',
    );
    expect(opened[1], 'sync:');
    await adb.close();
    await adbd.done();
  });
}
