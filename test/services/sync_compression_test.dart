// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/compression/lz4.dart';
import 'package:adb_direct/src/protocol/sync_protocol.dart';
import 'package:test/test.dart';

import '../compression/lz4_test.dart' show sample;
import '../connection/streams_test.dart' show connectTo;
import '../support/adbd_scripts.dart' show classicBanner;
import 'sync_test.dart' show SyncPeer;

Uint8List banner(String features) => utf8.encode('${utf8.decode(classicBanner)},$features');

/// Reads a push's DATA until DONE; returns the payload.
Future<Uint8List> receivePush(SyncPeer peer) async {
  final payload = BytesBuilder();
  while (true) {
    final (id, value) = await peer.header();
    if (id == 'DONE') break;
    expect(id, 'DATA');
    payload.add(await peer.read(value));
  }
  peer.send(SyncRequest.header(SyncId.okay, 0));
  return payload.takeBytes();
}

void main() {
  test('pull with LZ4: RCV2 flag 2, the recorded frame in pieces, decoded progress', () async {
    final frame = File('test/fixtures/sync/lz4_pull.bin').readAsBytesSync();
    final (adb, adbd) = await connectTo(banner: banner('sendrecv_v2,sendrecv_v2_lz4'), (session) async {
      final peer = await SyncPeer.accept(session);
      expect(await peer.request(), ('RCV2', '/s.txt'));
      expect(await peer.header(), ('RCV2', 2));
      for (var i = 0; i < frame.length; i += 20000) {
        final end = i + 20000 < frame.length ? i + 20000 : frame.length;
        peer.send(SyncRequest.header(SyncId.data, end - i, frame.sublist(i, end)));
      }
      peer.send(SyncRequest.header(SyncId.done, 0));
      await peer.settle();
    });
    expect(adb.sync.supportsCompression(AdbCompressionMethod.lz4), isTrue);
    expect(adb.sync.supportsCompression(AdbCompressionMethod.zstd), isFalse);
    var progress = 0;
    final chunks = await adb.sync
        .read('/s.txt', compression: AdbCompression.lz4, onProgress: (done, _) => progress = done)
        .toList();
    expect(chunks.expand((c) => c), sample());
    expect(progress, sample().length);
    await adbd.done();
    await adb.close();
  });

  test('push with LZ4: SND2 flag 2, a frame the device can decode, progress in source bytes', () async {
    late Uint8List sent;
    final (adb, adbd) = await connectTo(banner: banner('sendrecv_v2,sendrecv_v2_lz4'), (session) async {
      final peer = await SyncPeer.accept(session);
      expect(await peer.request(), ('SND2', '/s.txt'));
      final second = ByteData.sublistView(await peer.read(12));
      expect(second.getUint32(8, Endian.little), 2);
      sent = await receivePush(peer);
      await peer.settle();
    });
    final data = sample();
    final progress = <int>[];
    await adb.sync.write(
      '/s.txt',
      Stream.fromIterable([data.sublist(0, 100000), data.sublist(100000)]),
      size: data.length,
      compression: AdbCompression.lz4,
      onProgress: (done, _) => progress.add(done),
    );
    expect(Lz4Frame.decoder.convert(sent), data);
    expect(sent.length, lessThan(data.length ~/ 2));
    expect(progress.last, data.length);
    expect(progress, everyElement(inInclusiveRange(0, data.length)));
    await adbd.done();
    await adb.close();
  });

  test('no compression where the device lacks the method or sync v2, or the codec cannot encode', () async {
    final decodeOnly = AdbCompression(method: AdbCompressionMethod.lz4, decoder: Lz4Frame.decoder);
    for (final (features, compression) in [
      ('sendrecv_v2', AdbCompression.lz4),
      ('sendrecv_v2_lz4', AdbCompression.lz4),
      ('sendrecv_v2,sendrecv_v2_lz4', decodeOnly),
    ]) {
      final (adb, adbd) = await connectTo(banner: banner(features), (session) async {
        final peer = await SyncPeer.accept(session);
        final (id, _) = await peer.request();
        if (id == 'SND2') {
          final second = ByteData.sublistView(await peer.read(12));
          expect(second.getUint32(8, Endian.little), 0);
        } else {
          expect(id, 'SEND');
        }
        expect(await receivePush(peer), [1, 2, 3]);
        await peer.settle();
      });
      await adb.sync.writeAll('/x', [1, 2, 3], compression: compression);
      await adbd.done();
      await adb.close();
    }
  });

  test('compressed data that does not decode is a protocol error', () async {
    final (adb, adbd) = await connectTo(banner: banner('sendrecv_v2,sendrecv_v2_lz4'), (session) async {
      final peer = await SyncPeer.accept(session);
      await peer.request();
      await peer.header();
      peer.send(SyncRequest.header(SyncId.data, 8, [1, 2, 3, 4, 5, 6, 7, 8]));
      await peer.settle(anything: true);
    });
    await expectLater(
      adb.sync.readAll('/x', compression: AdbCompression.lz4),
      throwsA(isA<AdbProtocolException>().having((e) => e.message, 'message', contains('lz4 data of /x'))),
    );
    await adb.close();
    await adbd.done();
  });
}
