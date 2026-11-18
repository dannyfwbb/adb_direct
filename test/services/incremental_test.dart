// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/compression/lz4.dart';
import 'package:adb_direct/src/protocol/byte_queue.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/services/incremental.dart'
    show apkPriorityBlocks, incrementalArgument, parseIdsig, verityTreeBlocks;
import 'package:test/test.dart';

import '../connection/streams_test.dart' show connectTo;
import '../support/fake_adbd.dart';
import 'packages_test.dart' show abbBanner, cmdBanner;

AdbIncrementalApk fixture(String name, {bool signed = true}) {
  final apk = AdbIncrementalApk.file(File('test/fixtures/apks/$name.apk'));
  return signed ? apk : AdbIncrementalApk(name: apk.name, size: apk.size, read: apk.read, close: apk.close);
}

/// The device's side of `install-incremental`: the package manager's data loader.
final class LoaderPeer {
  LoaderPeer._(this.session, this.remoteId, this.service);

  static Future<LoaderPeer> accept(FakeAdbdSession session) async {
    final open = await session.receive();
    expect(open.command, AdbCommand.open);
    session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
    return LoaderPeer._(session, open.arg0, utf8.decode(open.payload).replaceAll(RegExp(r'\x00$'), ''));
  }

  final FakeAdbdSession session;
  final int remoteId;
  final String service;
  final ByteQueue _buffer = ByteQueue();
  bool clientClosed = false;

  List<String> get arguments => service.split('\u0000');

  Future<Uint8List> read(int count) async {
    while (_buffer.length < count) {
      final message = await session.receive();
      if (message.command == AdbCommand.close) {
        clientClosed = true;
        throw FakeAdbdFailure('client closed the stream');
      }
      if (message.command == AdbCommand.okay) continue;
      expect(message.command, AdbCommand.write, reason: '$message');
      _buffer.add(message.payload);
      session.send(AdbMessage.okay(localId: 9, remoteId: remoteId));
    }
    return _buffer.take(count);
  }

  void send(List<int> bytes) => session.send(AdbMessage.write(localId: 9, remoteId: remoteId, data: bytes));

  void request(int type, int fileId, int block) {
    final data = ByteData(12)
      ..setUint32(0, 0x494e4352)
      ..setInt16(4, type)
      ..setInt16(6, fileId)
      ..setInt32(8, block);
    send(data.buffer.asUint8List());
  }

  /// Reads one response chunk: its blocks as (file id, type, index, decoded data).
  Future<List<(int, int, int, Uint8List)>> chunk() async {
    final size = ByteData.sublistView(await read(4)).getInt32(0);
    final body = await read(size);
    final data = ByteData.sublistView(body);
    final blocks = <(int, int, int, Uint8List)>[];
    for (var at = 0; at < size;) {
      final fileId = data.getInt16(at);
      final type = data.getInt8(at + 2);
      final compression = data.getInt8(at + 3);
      final index = data.getInt32(at + 4);
      final length = data.getInt16(at + 8);
      final raw = Uint8List.sublistView(body, at + 10, at + 10 + length);
      at += 10 + length;
      if (compression == 1) {
        final out = Uint8List(4096);
        final end = Lz4.decompressBlock(raw, out);
        blocks.add((fileId, type, index, Uint8List.sublistView(out, 0, end)));
      } else {
        blocks.add((fileId, type, index, Uint8List.fromList(raw)));
      }
    }
    return blocks;
  }
}

void main() {
  final apkBytes = File('test/fixtures/apks/app-v1.apk').readAsBytesSync();
  final idsig = File('test/fixtures/apks/app-v1.apk.idsig').readAsBytesSync();

  group('pieces', () {
    test('verity tree sizes', () {
      expect(verityTreeBlocks(0), 0);
      expect(verityTreeBlocks(4096), 0);
      expect(verityTreeBlocks(4097), 1);
      expect(verityTreeBlocks(128 * 4096), 1);
      expect(verityTreeBlocks(128 * 4096 + 1), 3);
      expect(verityTreeBlocks(3158478), 8);
    });

    test('an .idsig from apksigner: header, tree position and size', () {
      final parts = parseIdsig(idsig, apkBytes.length);
      expect(parts.treeSize, 4096);
      expect(parts.treeOffset + parts.treeSize, idsig.length);
      expect(parts.header.length, parts.treeOffset - 4);
      expect(ByteData.sublistView(parts.header).getInt32(0, Endian.little), 2, reason: 'v4 signature version');
      expect(() => parseIdsig(idsig, apkBytes.length * 1000), throwsFormatException, reason: 'tree for another size');
      expect(() => parseIdsig(idsig.sublist(0, 100), apkBytes.length), throwsFormatException);
      expect(() => parseIdsig(idsig.sublist(0, idsig.length - 1), apkBytes.length), throwsFormatException);
      expect(incrementalArgument('a.apk', 5, 0, Uint8List.fromList([1, 2, 3])), 'a.apk:5:0:AQID:1');
      expect(incrementalArgument('b.dm', 7, 1, null), 'b.dm:7:1');
    });

    test('priority blocks of an APK: the signing block to the end, block 0, the manifest', () async {
      Future<Uint8List> read(int offset, int length) async => Uint8List.sublistView(apkBytes, offset, offset + length);
      final blocks = await apkPriorityBlocks(read, apkBytes.length);
      // 8530 bytes: blocks 0 to 2; the signing block and central directory sit in the last ones.
      expect(blocks.toSet(), {0, 1, 2});
      expect(blocks.first, isNot(0));
      expect(blocks, hasLength(3));
      expect(await apkPriorityBlocks((o, l) async => Uint8List(l), 10000), isEmpty, reason: 'not a zip');
    });
  });

  group('AdbIncrementalApk.file', () {
    test('concurrent reads each get their own bytes; reading again after close reopens', () async {
      final apk = fixture('app-v1');
      final reads = [for (var i = 0; i < 40; i++) apk.read((i * 197) % (apkBytes.length - 100), 100)];
      final results = await Future.wait(reads);
      for (var i = 0; i < 40; i++) {
        final offset = (i * 197) % (apkBytes.length - 100);
        expect(results[i], apkBytes.sublist(offset, offset + 100), reason: 'read $i');
      }
      await apk.close!();
      expect(await apk.read(0, 4), apkBytes.sublist(0, 4));
      await apk.close!();
      await apk.close!();
    });
  });

  group('installIncremental', () {
    test('arguments, OKAY, prefetch with tree and data blocks, a missing block, output split around INCR', () async {
      late LoaderPeer peer;
      final received = <int, Uint8List>{};
      final tree = <int>{};
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        peer = await LoaderPeer.accept(session);
        expect(ascii.decode(await peer.read(4)), 'OKAY');
        peer
          ..request(2, 0, 0)
          ..send(ascii.encode('Suc'))
          ..send([...ascii.encode('cessIN')])
          ..send([...ascii.encode('CR'), 0, 1, 0, 0, 0, 0, 0, 2]); // BLOCK_MISSING file 0 block 2
        var done = false;
        while (!done) {
          for (final (fileId, type, index, data) in await peer.chunk()) {
            if (fileId == -1) {
              done = true;
            } else if (type == 1) {
              expect(tree.add(index), isTrue, reason: 'tree block sent once');
            } else {
              expect(received.containsKey(index), isFalse, reason: 'data block sent once');
              received[index] = data;
            }
          }
        }
        peer
          ..send(ascii.encode('\n'))
          ..request(0, -1, -1);
        await expectLater(peer.read(1), throwsA(isA<FakeAdbdFailure>()));
        expect(peer.clientClosed, isTrue);
      });
      final install = await adb.packages.installIncremental([fixture('app-v1')]);
      expect(install.output, startsWith('Success'));
      await install.done;
      expect(install.isComplete, isTrue);
      expect(install.totalBlocks, 3);

      final parts = parseIdsig(idsig, apkBytes.length);
      expect(peer.arguments, [
        'abb_exec:package',
        'install-incremental',
        '-r',
        'app-v1.apk:${apkBytes.length}:0:${base64.encode(parts.header)}:1',
      ]);
      expect(tree, {0});
      expect([for (var i = 0; i < 3; i++) ...received[i]!], apkBytes);
      await adbd.done();
      await adb.close();
    });

    test('files without a signature go through stdin first; ids after the signed ones', () async {
      late LoaderPeer peer;
      final v2 = File('test/fixtures/apks/app-v2.apk').readAsBytesSync();
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        peer = await LoaderPeer.accept(session);
        expect(await peer.read(v2.length), v2);
        expect(ascii.decode(await peer.read(4)), 'OKAY');
        peer
          ..send(ascii.encode('Success\n'))
          ..request(0, -1, -1);
        await peer.read(1).then((_) {}, onError: (Object _) {});
      });
      final install = await adb.packages.installIncremental([
        fixture('app-v2', signed: false),
        fixture('app-v2-extra'),
      ], options: const AdbInstallOptions(grantPermissions: true));
      await install.done;
      expect(peer.arguments.sublist(1, 4), ['install-incremental', '-r', '-g']);
      expect(peer.arguments[4], startsWith('app-v2-extra.apk:8530:0:'));
      expect(peer.arguments[5], 'app-v2.apk:${v2.length}:1');
      await adbd.done();
      await adb.close();
    });

    test('a device that closes before it has every block fails done', () async {
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        final peer = await LoaderPeer.accept(session);
        await peer.read(4);
        // Installed, then gone without asking for anything.
        peer.send(ascii.encode('Success\n'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        session.send(AdbMessage.close(localId: 9, remoteId: peer.remoteId));
      });
      final install = await adb.packages.installIncremental([fixture('app-v1')]);
      await expectLater(install.done, throwsA(isA<AdbClosedException>()));
      expect(install.isComplete, isFalse);
      await adb.close();
      await adbd.done();
    });

    test('a refusal: AdbInstallException with the code; the stream is closed', () async {
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        final peer = await LoaderPeer.accept(session);
        await peer.read(4);
        peer.send(ascii.encode('Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]\n'));
        await expectLater(() async {
          while (true) {
            await peer.read(1);
          }
        }(), throwsA(isA<FakeAdbdFailure>()));
      });
      await expectLater(
        adb.packages.installIncremental([fixture('app-v1')]),
        throwsA(
          isA<AdbInstallException>().having((e) => e.failureCode, 'failureCode', 'INSTALL_FAILED_VERSION_DOWNGRADE'),
        ),
      );
      await adbd.done();
      await adb.close();
    });

    test('a read that returns the wrong number of bytes fails the install, not the device', () async {
      final good = fixture('app-v1');
      final short = AdbIncrementalApk(
        name: good.name,
        size: good.size,
        signature: good.signature,
        read: (offset, length) async => (await good.read(offset, length)).sublist(0, length > 10 ? 10 : length),
      );
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        final peer = await LoaderPeer.accept(session);
        await peer.read(4);
        peer
          ..send(ascii.encode('Success\n'))
          ..request(2, 0, 0);
        await peer.read(1).then((_) {}, onError: (Object _) {});
      });
      final install = await adb.packages.installIncremental([short]);
      await expectLater(install.done, throwsArgumentError);
      await adb.close();
      await adbd.done();
    });

    test('output split inside a UTF-8 character stays whole', () async {
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        final peer = await LoaderPeer.accept(session);
        await peer.read(4);
        final text = utf8.encode('Готово Success\n');
        peer
          ..send(text.sublist(0, 1))
          ..send(text.sublist(1))
          ..request(0, -1, -1);
        await peer.read(1).then((_) {}, onError: (Object _) {});
      });
      final install = await adb.packages.installIncremental([fixture('app-v1')]);
      expect(install.output, 'Готово Success\n');
      await install.done;
      await adb.close();
      await adbd.done();
    });

    test('checks before anything is sent', () async {
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {});
      await expectLater(adb.packages.installIncremental([fixture('app-v1')]), throwsA(isA<AdbNotSupportedException>()));
      expect(() => adb.packages.installIncremental([]), throwsArgumentError);
      final apk = fixture('app-v1');
      expect(() => adb.packages.installIncremental([apk, apk]), throwsArgumentError);
      final badName = AdbIncrementalApk(name: 'a:b.apk', size: 1, read: apk.read);
      expect(() => adb.packages.installIncremental([badName]), throwsArgumentError);
      await adb.close();
      await adbd.done();

      final (adb2, adbd2) = await connectTo(banner: abbBanner, (session) async {});
      final wrongSignature = AdbIncrementalApk(
        name: 'x.apk',
        size: apkBytes.length * 100,
        read: apk.read,
        signature: idsig,
      );
      expect(() => adb2.packages.installIncremental([wrongSignature]), throwsArgumentError);
      await adb2.close();
      await adbd2.done();
    });
  });
}
