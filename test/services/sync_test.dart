// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/byte_queue.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/protocol/sync_protocol.dart';
import 'package:test/test.dart';

import '../connection/streams_test.dart' show connectTo, noLiveness;
import '../support/adbd_scripts.dart' show classicBanner, oldBanner;
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

/// adbd's side of one `sync:` stream inside a fake session: acknowledges the client's writes and lets the script read
/// the sync bytes they carry.
final class SyncPeer {
  SyncPeer._(this.session, this.localId, this.remoteId);

  /// Waits for `OPEN sync:` and accepts it as device stream [deviceId].
  static Future<SyncPeer> accept(FakeAdbdSession session, {int deviceId = 9}) async {
    var open = await session.receive();
    // Leftovers of an earlier stream: acknowledgements, a close.
    while (open.command == AdbCommand.okay || open.command == AdbCommand.close) {
      open = await session.receive();
    }
    expect(open.command, AdbCommand.open);
    expect(utf8.decode(open.payload), 'sync:\u0000');
    session.send(AdbMessage.okay(localId: deviceId, remoteId: open.arg0));
    return SyncPeer._(session, deviceId, open.arg0);
  }

  final FakeAdbdSession session;
  final int localId;
  final int remoteId;
  final ByteQueue _buffer = ByteQueue();

  /// Reads [count] sync bytes the client wrote.
  Future<Uint8List> read(int count) async {
    while (_buffer.length < count) {
      final message = await session.receive();
      if (message.command == AdbCommand.close) throw FakeAdbdFailure('client closed the sync stream');
      // The client's acknowledgements of what we sent.
      if (message.command == AdbCommand.okay) continue;
      expect(message.command, AdbCommand.write, reason: '$message');
      _buffer.add(message.payload);
      session.send(AdbMessage.okay(localId: localId, remoteId: remoteId));
    }
    return _buffer.take(count);
  }

  /// Reads `{id, value}` and returns them.
  Future<(String, int)> header() async {
    final data = ByteData.sublistView(await read(8));
    return (SyncId.name(data.getUint32(0, Endian.little)), data.getUint32(4, Endian.little));
  }

  /// Reads a request with a path: `{id, length}` + path.
  Future<(String, String)> request() async {
    final (id, length) = await header();
    return (id, utf8.decode(await read(length)));
  }

  /// Sends sync bytes to the client.
  void send(List<int> bytes) => session.send(AdbMessage.write(localId: localId, remoteId: remoteId, data: bytes));

  /// Sends `FAIL` with [message], then closes, as adbd does after a failed read or listing.
  void fail(String message) {
    final bytes = utf8.encode(message);
    send(SyncRequest.header(SyncId.fail, bytes.length, bytes));
    session.send(AdbMessage.close(localId: localId, remoteId: remoteId));
  }

  /// Fails a push as adbd does: `FAIL` at once, then it keeps reading the client's `DATA` until `DONE`, then closes.
  /// Returns how many data bytes arrived after the failure.
  Future<int> failPush(String message) async {
    final bytes = utf8.encode(message);
    send(SyncRequest.header(SyncId.fail, bytes.length, bytes));
    var drained = 0;
    while (true) {
      final (id, value) = await header();
      if (id == 'DONE') break;
      expect(id, 'DATA');
      await read(value);
      drained += value;
    }
    session.send(AdbMessage.close(localId: localId, remoteId: remoteId));
    return drained;
  }

  /// Takes the client's trailing acknowledgements for [window]; any other message fails, unless [anything] is set (a
  /// client still sending what it had queued when the device failed).
  Future<void> settle({Duration window = const Duration(milliseconds: 100), bool anything = false}) async {
    while (true) {
      final AdbMessage message;
      try {
        message = await session.receive(timeout: window);
      } on FakeAdbdFailure {
        return; // Quiet, or the client closed.
      }
      if (!anything && message.command != AdbCommand.okay) {
        throw FakeAdbdFailure('unexpected message from the client: $message');
      }
    }
  }

  /// Expects `QUIT` and the close that follows.
  Future<void> expectQuit() async {
    expect(await header(), ('QUIT', 0));
    var message = await session.receive();
    while (message.command == AdbCommand.okay) {
      message = await session.receive();
    }
    expect(message.command, AdbCommand.close);
  }
}

Uint8List stat1(int mode, int size, int mtime) {
  final out = Uint8List(16);
  ByteData.sublistView(out)
    ..setUint32(0, SyncId.stat, Endian.little)
    ..setUint32(4, mode, Endian.little)
    ..setUint32(8, size, Endian.little)
    ..setUint32(12, mtime, Endian.little);
  return out;
}

Uint8List stat2(int id, {int error = 0, int mode = 0, int size = 0}) {
  final out = Uint8List(72);
  ByteData.sublistView(out)
    ..setUint32(0, id, Endian.little)
    ..setUint32(4, error, Endian.little)
    ..setUint32(24, mode, Endian.little)
    ..setUint64(40, size, Endian.little)
    ..setInt64(56, 1700000000, Endian.little);
  return out;
}

Uint8List dent1(String name, int mode, int size) {
  final out = Uint8List(20 + name.length);
  ByteData.sublistView(out)
    ..setUint32(0, SyncId.dent, Endian.little)
    ..setUint32(4, mode, Endian.little)
    ..setUint32(8, size, Endian.little)
    ..setUint32(12, 1700000000, Endian.little)
    ..setUint32(16, name.length, Endian.little);
  out.setRange(20, out.length, name.codeUnits);
  return out;
}

void main() {
  group('devices without sync v2 (Android 7 and older)', () {
    test('STAT: a file, and zeros for a missing path', () async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('STAT', '/a'));
        peer.send(stat1(0x81a4, 12, 1700000000));
        expect(await peer.request(), ('STAT', '/missing'));
        peer.send(stat1(0, 0, 0));
        await peer.settle();
      });
      final file = await adb.sync.stat('/a');
      expect(file!.isFile, isTrue);
      expect(file.size, 12);
      expect(file.modified, DateTime.utc(2023, 11, 14, 22, 13, 20));
      expect(await adb.sync.stat('/missing'), isNull);
      await expectLater(adb.sync.stat('/a', followLinks: true), throwsA(isA<AdbNotSupportedException>()));
      await adbd.done();
      await adb.close();
    });

    test('LIST, RECV and SEND "path,mode"', () async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('LIST', '/d'));
        peer
          ..send(dent1('.', 0x41ed, 0))
          ..send(dent1('f', 0x81a4, 3))
          ..send(SyncRequest.header(SyncId.done, 0, Uint8List(12)));
        expect(await peer.request(), ('RECV', '/d/f'));
        peer
          ..send(SyncRequest.header(SyncId.data, 2, [1, 2]))
          ..send(SyncRequest.header(SyncId.data, 1, [3]))
          ..send(SyncRequest.header(SyncId.done, 0));
        expect(await peer.request(), ('SEND', '/d/g,${0x81ed}'));
        expect(await peer.header(), ('DATA', 2));
        expect(await peer.read(2), [7, 8]);
        expect(await peer.header(), ('DONE', 1000));
        peer.send(SyncRequest.header(SyncId.okay, 0));
        await peer.settle();
      });
      final entries = await adb.sync.list('/d');
      expect(entries.map((e) => e.name), ['f']);
      expect(await adb.sync.readAll('/d/f'), [1, 2, 3]);
      await adb.sync.writeAll(
        '/d/g',
        [7, 8],
        permissions: 0x1ed,
        modified: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      );
      await adbd.done();
      await adb.close();
    });
  });

  group('sync v2', () {
    test('STA2 and LST2; errno becomes an AdbSyncException', () async {
      final (adb, adbd) = await connectTo(banner: utf8.encode('${utf8.decode(classicBanner)},sendrecv_v2'), (
        session,
      ) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('LST2', '/l'));
        peer.send(stat2(SyncId.lstat2, mode: 0xa1ff));
        expect(await peer.request(), ('STA2', '/l'));
        peer.send(stat2(SyncId.stat2, mode: 0x41f9, size: 1 << 33));
        expect(await peer.request(), ('LST2', '/gone'));
        peer.send(stat2(SyncId.lstat2, error: 2));
        expect(await peer.request(), ('LST2', '/secret'));
        peer.send(stat2(SyncId.lstat2, error: 13));
        await peer.settle();
      });
      expect((await adb.sync.stat('/l'))!.isLink, isTrue);
      final target = await adb.sync.stat('/l', followLinks: true);
      expect(target!.isDirectory, isTrue);
      expect(target.size, 1 << 33);
      expect(await adb.sync.stat('/gone'), isNull);
      await expectLater(
        adb.sync.stat('/secret'),
        throwsA(
          isA<AdbSyncException>()
              .having((e) => e.path, 'path', '/secret')
              .having((e) => e.message, 'message', contains('EACCES')),
        ),
      );
      await adbd.done();
      await adb.close();
    });

    test('RCV2 and SND2 with their second parts; DATA split at 64 KiB', () async {
      final banner = utf8.encode('${utf8.decode(classicBanner)},sendrecv_v2');
      final (adb, adbd) = await connectTo(banner: banner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('RCV2', '/r'));
        expect(await peer.header(), ('RCV2', 0));
        peer
          ..send(SyncRequest.header(SyncId.data, 1, [5]))
          ..send(SyncRequest.header(SyncId.done, 0));
        expect(await peer.request(), ('SND2', '/w'));
        final second = ByteData.sublistView(await peer.read(12));
        expect(SyncId.name(second.getUint32(0, Endian.little)), 'SND2');
        expect(second.getUint32(4, Endian.little), 0x81a4);
        expect(second.getUint32(8, Endian.little), 0);
        final sizes = <int>[];
        while (true) {
          final (id, value) = await peer.header();
          if (id == 'DONE') break;
          expect(id, 'DATA');
          sizes.add(value);
          await peer.read(value);
        }
        expect(sizes, [65536, 65536, 22528]);
        peer.send(SyncRequest.header(SyncId.okay, 0));
        await peer.settle();
      });
      expect(await adb.sync.readAll('/r'), [5]);
      await adb.sync.writeAll('/w', Uint8List(150 * 1024));
      await adbd.done();
      await adb.close();
    });
  });

  group('failures and sessions', () {
    test('a FAIL ends the session; the next call opens a new one', () async {
      final (adb, adbd) = await connectTo((session) async {
        final first = await SyncPeer.accept(session);
        expect(await first.request(), ('RECV', '/secret'));
        first.fail('open failed: Permission denied');
        final second = await SyncPeer.accept(session, deviceId: 10);
        expect(await second.request(), ('LST2', '/ok'));
        second.send(stat2(SyncId.lstat2, mode: 0x81a4));
        await second.settle();
      });
      await expectLater(
        adb.sync.readAll('/secret'),
        throwsA(isA<AdbSyncException>().having((e) => e.message, 'message', 'open failed: Permission denied')),
      );
      expect((await adb.sync.stat('/ok'))!.isFile, isTrue);
      await adbd.done();
      await adb.close();
    });

    test('a FAIL in the middle of a push stops the upload early', () async {
      late int drained;
      final (adb, adbd) = await connectTo((session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('SEND', '/full,${0x81a4}'));
        final (id, value) = await peer.header();
        expect(id, 'DATA');
        await peer.read(value);
        drained = await peer.failPush('No space left on device');
        await peer.settle(anything: true);
      });
      await expectLater(
        adb.sync.writeAll('/full', Uint8List(4 * 1024 * 1024)),
        throwsA(isA<AdbSyncException>().having((e) => e.message, 'message', 'No space left on device')),
      );
      await adbd.done();
      // Not the whole 4 MiB: the client noticed the FAIL and sent DONE.
      expect(drained, lessThan(1024 * 1024));
      await adb.close();
    });

    test('a transfer without progress fails; the connection stays', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('RECV', '/slow'));
        peer.send(SyncRequest.header(SyncId.data, 1, [1]));
        await peer.settle(window: const Duration(milliseconds: 50));
        clock.advance(const Duration(seconds: 31));
        var close = await session.receive();
        while (close.command == AdbCommand.okay) {
          close = await session.receive();
        }
        expect(close.command, AdbCommand.close);
      });
      await expectLater(adb.sync.readAll('/slow'), throwsA(isA<AdbTimeoutException>()));
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });

    test('calls in a row share a session, which quits when idle', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (session) async {
        final peer = await SyncPeer.accept(session);
        for (final path in ['/1', '/2']) {
          expect(await peer.request(), ('LST2', path));
          peer.send(stat2(SyncId.lstat2, mode: 0x81a4));
        }
        await peer.settle(window: const Duration(milliseconds: 50));
        clock.advance(const Duration(seconds: 3));
        await peer.expectQuit();
      });
      await adb.sync.stat('/1');
      await adb.sync.stat('/2');
      await adbd.done();
      await adb.close();
    });

    test('a path longer than 1024 bytes is refused before sending', () async {
      final (adb, adbd) = await connectTo((session) async {
        // Not even a sync session is opened.
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      await expectLater(adb.sync.stat('/${'x' * 1024}'), throwsArgumentError);
      await expectLater(
        adb.sync.writeAll('/${'x' * 1023}', [1]),
        throwsArgumentError,
        reason: 'v1 sends "path,mode", which is longer',
      );
      await adbd.done();
      await adb.close();
    });
  });

  group('more of the protocol', () {
    Uint8List dent2(String name, {int error = 0, int mode = 0x81a4}) {
      final out = Uint8List(76 + name.length);
      ByteData.sublistView(out)
        ..setUint32(0, SyncId.dent2, Endian.little)
        ..setUint32(4, error, Endian.little)
        ..setUint32(24, mode, Endian.little)
        ..setUint32(72, name.length, Endian.little);
      out.setRange(76, out.length, name.codeUnits);
      return out;
    }

    final v2Banner = utf8.encode('${utf8.decode(classicBanner)},sendrecv_v2');

    test('LIS2: entries, an entry with an errno left out, padded DONE', () async {
      final (adb, adbd) = await connectTo(banner: v2Banner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('LIS2', '/d'));
        peer
          ..send(dent2('..', mode: 0x41ed))
          ..send(dent2('ok'))
          ..send(dent2('vanished', error: 2))
          ..send(SyncRequest.header(SyncId.done, 0, Uint8List(68)));
        expect(await peer.request(), ('LST2', '/next'));
        peer.send(stat2(SyncId.lstat2, mode: 0x81a4));
        await peer.settle();
      });
      expect((await adb.sync.list('/d')).map((e) => e.name), ['ok']);
      // The session is still in step after the padded DONE.
      expect((await adb.sync.stat('/next'))!.isFile, isTrue);
      await adbd.done();
      await adb.close();
    });

    test('a read cancelled midway abandons its session; the next call opens a new one', () async {
      final (adb, adbd) = await connectTo(banner: v2Banner, (session) async {
        final first = await SyncPeer.accept(session);
        expect(await first.request(), ('RCV2', '/big'));
        await first.header();
        first.send(SyncRequest.header(SyncId.data, 3, [1, 2, 3]));
        final second = await SyncPeer.accept(session, deviceId: 10);
        expect(await second.request(), ('LST2', '/x'));
        second.send(stat2(SyncId.lstat2, mode: 0x81a4));
        await second.settle();
      });
      await adb.sync.read('/big').first;
      expect((await adb.sync.stat('/x'))!.isFile, isTrue);
      await adbd.done();
      await adb.close();
    });

    test('a source that fails mid-write fails the write and drops the session', () async {
      final (adb, adbd) = await connectTo(banner: v2Banner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('SND2', '/w'));
        await peer.read(12);
        expect(await peer.header(), ('DATA', 2));
        await peer.read(2);
        var message = await session.receive();
        while (message.command == AdbCommand.okay) {
          message = await session.receive();
        }
        expect(message.command, AdbCommand.close);
      });
      Stream<List<int>> source() async* {
        yield [1, 2];
        throw const FileSystemException('disk gone');
      }

      await expectLater(adb.sync.write('/w', source()), throwsA(isA<FileSystemException>()));
      await adbd.done();
      await adb.close();
    });

    test('a frame cut short, then silence, fails as a stall', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('RECV', '/cut'));
        peer.send(Uint8List.fromList([...SyncRequest.header(SyncId.data, 10), 1, 2, 3]));
        await peer.settle(window: const Duration(milliseconds: 50));
        clock.advance(const Duration(seconds: 31));
        await peer.settle(anything: true);
      });
      await expectLater(adb.sync.readAll('/cut'), throwsA(isA<AdbTimeoutException>()));
      await adbd.done();
      await adb.close();
    });

    test('a push the device stops acknowledging fails as a stall', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (session) async {
        final open = await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        await session.receive(); // the SEND request, never acknowledged
        clock.advance(const Duration(seconds: 31));
        // The overdue acknowledgement makes the connection check the device (it answers: alive); the push watchdog then
        // gives up.
        while (true) {
          final message = await session.receive();
          if (message.command == AdbCommand.open) {
            session.send(AdbMessage.close(localId: 0, remoteId: message.arg0));
            continue;
          }
          expect(message.command, AdbCommand.close);
          break;
        }
      });
      await expectLater(adb.sync.writeAll('/w', [1]), throwsA(isA<AdbTimeoutException>()));
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });

    test('writeLink pushes a link with its target as data', () async {
      final (adb, adbd) = await connectTo(banner: v2Banner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('SND2', '/l'));
        final second = ByteData.sublistView(await peer.read(12));
        expect(second.getUint32(4, Endian.little), 0xa1ff);
        expect(await peer.header(), ('DATA', 4));
        expect(utf8.decode(await peer.read(4)), '/sdx');
        expect((await peer.header()).$1, 'DONE');
        peer.send(SyncRequest.header(SyncId.okay, 0));
        await peer.settle();
      });
      await adb.sync.writeLink('/l', '/sdx');
      await adbd.done();
      await adb.close();
    });

    test('operations at once use separate sessions', () async {
      final (adb, adbd) = await connectTo(banner: v2Banner, (session) async {
        final opens = <int>[];
        for (var i = 0; i < 2; i++) {
          final open = await session.receive();
          expect(utf8.decode(open.payload), 'sync:\u0000');
          opens.add(open.arg0);
          session.send(AdbMessage.okay(localId: 20 + i, remoteId: open.arg0));
        }
        for (var i = 0; i < 2; i++) {
          final request = await session.receive();
          session
            ..send(AdbMessage.okay(localId: 20 + opens.indexOf(request.arg0), remoteId: request.arg0))
            ..send(
              AdbMessage.write(
                localId: 20 + opens.indexOf(request.arg0),
                remoteId: request.arg0,
                data: stat2(SyncId.lstat2, mode: 0x81a4),
              ),
            );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final results = await Future.wait([adb.sync.stat('/a'), adb.sync.stat('/b')]);
      expect(results.every((r) => r!.isFile), isTrue);
      await adbd.done();
      await adb.close();
    });

    test('pullFile on an old device: STAT, then RECV, mtime kept', () async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        final peer = await SyncPeer.accept(session);
        expect(await peer.request(), ('STAT', '/f'));
        peer.send(stat1(0x81a4, 2, 1700000000));
        expect(await peer.request(), ('RECV', '/f'));
        peer
          ..send(SyncRequest.header(SyncId.data, 2, [4, 2]))
          ..send(SyncRequest.header(SyncId.done, 0));
        await peer.settle();
      });
      final dir = await Directory.systemTemp.createTemp('pull');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/f');
      await adb.sync.pullFile('/f', file);
      expect(file.readAsBytesSync(), [4, 2]);
      expect(file.lastModifiedSync().toUtc(), DateTime.utc(2023, 11, 14, 22, 13, 20));
      expect(dir.listSync(), hasLength(1), reason: 'no partial file left');
      await adbd.done();
      await adb.close();
    });

    test('times outside the 32-bit seconds range are refused', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      await expectLater(adb.sync.writeAll('/t', [1], modified: DateTime.utc(1969)), throwsArgumentError);
      await adbd.done();
      await adb.close();
    });
  });
}
