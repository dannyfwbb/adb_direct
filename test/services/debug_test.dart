// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/services/debug.dart'
    show BugreportDone, BugreportFailed, BugreportLine, BugreportProgress, decodeAppProcesses;
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

Uint8List fixture(String name) => File('test/fixtures/services/$name').readAsBytesSync();

/// Connects to a fake whose script gets the next OPEN (its service and the client's id) after the handshake.
Future<(AdbConnection, FakeAdbd)> serve(
  Future<void> Function(FakeAdbdSession session, String service, int id) script, {
  Uint8List? banner,
}) async {
  final adbd = await FakeAdbd.start((session) async {
    await acceptHandshake(session, banner: banner ?? classicBanner);
    final open = await session.receive();
    session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
    await script(session, utf8.decode(open.payload).replaceAll('\u0000', ''), open.arg0);
  });
  final adb = await AdbConnection.connect(
    adbd.address,
    adbd.port,
    key: testKey,
    options: const AdbConnectOptions(livenessInterval: null),
  );
  return (adb, adbd);
}

void write(FakeAdbdSession session, int id, List<int> data) =>
    session.send(AdbMessage.write(localId: 9, remoteId: id, data: data));

void close(FakeAdbdSession session, int id) => session.send(AdbMessage.close(localId: 9, remoteId: id));

/// Reads what the client writes until [count] bytes arrived, acknowledging.
Future<List<int>> readFromClient(FakeAdbdSession session, int id, int count) async {
  final got = <int>[];
  while (got.length < count) {
    final m = await session.receive();
    if (m.command != AdbCommand.write) continue;
    got.addAll(m.payload);
    session.send(AdbMessage.okay(localId: 9, remoteId: id));
  }
  return got;
}

void main() {
  group('track-app protobuf (recorded)', () {
    test('the TV: three processes with an architecture, nothing else', () {
      final frame = fixture('track_app_tv.bin');
      final processes = decodeAppProcesses(Uint8List.sublistView(frame, 4));
      expect(processes, hasLength(3));
      expect(processes.map((p) => p.architecture).toSet(), {'x86'});
      expect(processes.every((p) => p.profileable && !p.debuggable), isTrue);
      expect(processes.first.pid, 1234);
      expect(processes.first.packageNames, isEmpty);
    });

    test('the phone: names, packages, uid; the debuggable app', () {
      final frame = fixture('track_app_phone.bin');
      final length = int.parse(ascii.decode(frame.sublist(0, 4)), radix: 16);
      expect(frame.length, 4 + length);
      final processes = decodeAppProcesses(Uint8List.sublistView(frame, 4));
      final app = processes.firstWhere((p) => p.packageNames.contains('com.example1'));
      expect(app.debuggable, isTrue);
      expect(app.processName, 'com.example1');
      expect(app.architecture, 'x86_64');
      expect(app.uid, isPositive);
      expect(processes.where((p) => p.processName == 'com.android.systemui'), hasLength(1));
    });

    test('truncated input is a protocol error', () {
      final frame = fixture('track_app_tv.bin');
      expect(() => decodeAppProcesses(Uint8List.sublistView(frame, 4, 20)), throwsA(isA<AdbProtocolException>()));
    });
  });

  group('tracking streams', () {
    test('track-jdwp frames split across messages', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        expect(service, 'track-jdwp');
        final frame = fixture('track_jdwp.bin');
        write(session, id, frame.sublist(0, 2));
        write(session, id, frame.sublist(2, 6));
        write(session, id, [...frame.sublist(6), ...ascii.encode('0000')]);
        await session.expectClientClose(timeout: const Duration(seconds: 5)).catchError((Object _) {});
      });
      final lists = await adb.debug.trackJdwp().take(2).toList();
      expect(lists, [
        [8646],
        <int>[],
      ]);
      await adb.close();
      await adbd.done();
    });

    test('a tracking stream that ends inside a frame is a protocol error, after the whole frames', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        write(session, id, [...ascii.encode('0005'), ...ascii.encode('8646\n'), ...ascii.encode('000a12')]);
        close(session, id);
        await session.expectClientClose(timeout: const Duration(seconds: 5)).catchError((Object _) {});
      });
      final lists = <List<int>>[];
      await expectLater(adb.debug.trackJdwp().forEach(lists.add), throwsA(isA<AdbProtocolException>()));
      expect(lists, [
        [8646],
      ]);
      await adb.close();
      await adbd.done();
    });

    test('track-app needs the feature', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        await session.expectClientClose();
      });
      final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
      await expectLater(adb.debug.trackApps().first, throwsA(isA<AdbNotSupportedException>()));
      await adb.close();
      await adbd.done();
    });

    test('track-app through the stream', () async {
      final banner = utf8.encode('device::ro.product.model=TV;features=shell_v2,track_app');
      final (adb, adbd) = await serve(banner: banner, (session, service, id) async {
        expect(service, 'track-app');
        final frame = fixture('track_app_tv.bin');
        write(session, id, frame.sublist(0, 10));
        write(session, id, frame.sublist(10));
        await session.expectClientClose(timeout: const Duration(seconds: 5)).catchError((Object _) {});
      });
      final first = await adb.debug.trackApps().first;
      expect(first.map((p) => p.pid), [1234, 1109, 1236]);
      await adb.close();
      await adbd.done();
    });
  });

  group('screencap deadline and limit', () {
    test('a capture that never ends times out; the stream closes and the connection stays', () async {
      final clock = FakeClock();
      final started = Completer<void>();
      final closed = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        final open = await session.receive();
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: open.arg0))
          ..send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: [0x89, 0x50, 0x4e, 0x47]));
        started.complete();
        while (true) {
          final m = await session.receive();
          if (m.command == AdbCommand.close) break;
        }
        closed.complete();
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        clock: clock,
        options: const AdbConnectOptions(livenessInterval: null),
      );
      final call = adb.debug.screencap(timeout: const Duration(seconds: 3));
      await started.future;
      clock.advance(const Duration(seconds: 3));
      await expectLater(call, throwsA(isA<AdbTimeoutException>()));
      await closed.future.timeout(const Duration(seconds: 5));
      expect(adb.isClosed, isFalse);
      await adb.close();
      await adbd.done();
    });

    test('more than maxBytes is a command error', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        write(session, id, List.filled(64, 0x89));
        await session.expectClientClose(timeout: const Duration(seconds: 5)).catchError((Object _) {});
      });
      await expectLater(
        adb.debug.screencap(maxBytes: 16),
        throwsA(isA<AdbCommandException>().having((e) => e.command, 'command', 'screencap -p')),
      );
      await adb.close();
      await adbd.done();
    });

    test('maxBytes must be positive', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        close(session, id);
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      await expectLater(adb.debug.screencap(maxBytes: 0), throwsArgumentError);
      await adb.shell.exec('true').then((s) => s.close(), onError: (Object _) {});
      await adb.close();
      await adbd.done();
    });
  });

  group('logcat, screencap, bug reports', () {
    test('logcat lines across message boundaries', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        expect(service, "exec:logcat -d '*:W'");
        write(session, id, utf8.encode('first li'));
        write(session, id, utf8.encode('ne\nsecond line\nthi'));
        write(session, id, utf8.encode('rd\n'));
        close(session, id);
      });
      expect(await adb.debug.logcat(arguments: ['-d', '*:W']).toList(), ['first line', 'second line', 'third']);
      await adb.close();
      await adbd.done();
    });

    test('screencap returns the PNG; anything else is an error', () async {
      final png = [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 1, 2, 3];
      final (adb, adbd) = await serve((session, service, id) async {
        expect(service, 'exec:screencap -p');
        write(session, id, png);
        close(session, id);
      });
      expect(await adb.debug.screencap(), png);
      await adb.close();
      await adbd.done();

      final (adb2, adbd2) = await serve((session, _, id) async {
        write(session, id, utf8.encode('Error: no display\n'));
        close(session, id);
      });
      await expectLater(
        adb2.debug.screencap(),
        throwsA(isA<AdbProtocolException>().having((e) => e.message, 'message', contains('no display'))),
      );
      await adb2.close();
      await adbd2.done();
    });

    test('bugreportz lines', () {
      expect(
        BugreportLine.parse('PROGRESS:12/345'),
        isA<BugreportProgress>().having((p) => (p.done, p.total), 'done, total', (12, 345)),
      );
      expect(
        BugreportLine.parse('OK:/bugreports/x.zip'),
        isA<BugreportDone>().having((d) => d.path, 'path', '/bugreports/x.zip'),
      );
      expect(
        BugreportLine.parse('FAIL:could not create'),
        isA<BugreportFailed>().having((f) => f.reason, 'reason', 'could not create'),
      );
      expect(BugreportLine.parse('BEGIN:/bugreports/x.zip'), isNull);
      expect(BugreportLine.parse('PROGRESS:x/y'), isNull);
    });
  });

  group('sideload', () {
    late Directory dir;
    late File package;
    late Uint8List content;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('sideload');
      content = Uint8List.fromList(List.generate(AdbRecovery.blockSize * 2 + 100, (i) => i * 13));
      package = File('${dir.path}/ota.zip')..writeAsBytesSync(content);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('serves the blocks the device asks for, in its order', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        expect(service, 'sideload-host:${content.length}:65536');
        for (final block in [2, 0, 2]) {
          write(session, id, ascii.encode(block.toString().padLeft(8, '0')));
          final want = block == 2 ? 100 : AdbRecovery.blockSize;
          final got = await readFromClient(session, id, want);
          final start = block * AdbRecovery.blockSize;
          expect(got, content.sublist(start, start + want));
        }
        write(session, id, ascii.encode('DONEDONE'));
        await session.receive(); // CLSE
      });
      final progress = <int>[];
      await adb.recovery.sideload(package, onProgress: (done, _) => progress.add(done));
      expect(progress, [100, 100 + AdbRecovery.blockSize, 200 + AdbRecovery.blockSize]);
      await adb.close();
      await adbd.done();
    });

    test('a request that is no block number is a protocol error', () async {
      final (adb, adbd) = await serve((session, _, id) async {
        write(session, id, ascii.encode('-0000001'));
        await session.receive();
      });
      await expectLater(adb.recovery.sideload(package), throwsA(isA<AdbProtocolException>()));
      await adb.close();
      await adbd.done();
    });

    test('FAILFAIL and a block past the end are errors', () async {
      final (adb, adbd) = await serve((session, _, id) async {
        write(session, id, ascii.encode('FAILFAIL'));
        await session.receive();
      });
      await expectLater(adb.recovery.sideload(package), throwsA(isA<AdbServiceUnavailableException>()));
      await adb.close();
      await adbd.done();

      final (adb2, adbd2) = await serve((session, _, id) async {
        write(session, id, ascii.encode('00000009'));
        await session.receive();
      });
      await expectLater(adb2.recovery.sideload(package), throwsA(isA<AdbProtocolException>()));
      await adb2.close();
      await adbd2.done();
    });

    test('a device without sideload-host gets the whole file', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        final first = await session.receive();
        session.send(AdbMessage.close(localId: 0, remoteId: first.arg0));
        final open = await session.receive();
        expect(utf8.decode(open.payload), 'sideload:${content.length}\u0000');
        session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        expect(await readFromClient(session, open.arg0, content.length), content);
        close(session, open.arg0);
      });
      final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
      await adb.recovery.sideload(package);
      await adb.close();
      await adbd.done();
    });
  });

  group('backup and restore', () {
    test('a restore the device drops fails cleanly', () async {
      final (adb, adbd) = await serve((session, _, id) async {
        await readFromClient(session, id, 2);
        close(session, id);
      });
      await expectLater(
        adb.backup.restore(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
            [5, 6],
          ]).asyncMap((c) async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return c;
          }),
        ),
        throwsA(isA<AdbException>()),
      );
      await adb.close();
      await adbd.done();
    });

    test('backup streams the archive; restore sends one', () async {
      final (adb, adbd) = await serve((session, service, id) async {
        expect(service, "backup: -apk com.example.app 'two words'");
        write(session, id, [1, 2, 3]);
        write(session, id, [4]);
        close(session, id);
      });
      final archive = await adb.backup.create(['-apk', 'com.example.app', 'two words']).expand((c) => c).toList();
      expect(archive, [1, 2, 3, 4]);
      await adb.close();
      await adbd.done();

      final (adb2, adbd2) = await serve((session, service, id) async {
        expect(service, 'restore:');
        expect(await readFromClient(session, id, 4), [1, 2, 3, 4]);
        // We close once everything is acknowledged, as adb does.
        final m = await session.receive();
        expect(m.command, AdbCommand.close);
      });
      await adb2.backup.restore(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
      );
      await adb2.close();
      await adbd2.done();
    });
  });
}
