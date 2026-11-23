// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

final Map<String, String> answers =
    (jsonDecode(File('test/fixtures/services/answers.json').readAsStringSync()) as Map<String, Object?>)
        .cast<String, String>();

/// Connects to a fake that answers one service with [text], closing the stream ([closeStream]) or dropping the whole
/// connection after it.
Future<(AdbConnection, FakeAdbd, Completer<String>)> serve(String text, {bool closeStream = true}) async {
  final service = Completer<String>();
  final adbd = await FakeAdbd.start((session) async {
    await acceptHandshake(session, banner: classicBanner);
    final open = await session.receive();
    service.complete(utf8.decode(open.payload).replaceAll('\u0000', ''));
    session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
    if (text.isNotEmpty) {
      session.send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: utf8.encode(text)));
    }
    if (closeStream) {
      session.send(AdbMessage.close(localId: 9, remoteId: open.arg0));
      await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
    } else {
      // adbd restarting: its process ends and the socket closes after what was written. A reset here would let
      // Windows drop the answer before it is read.
      await session.close();
    }
  });
  final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
  return (adb, adbd, service);
}

/// Accepts the next OPEN, sends [text] and stays silent until the client closes the stream. Returns the service.
Future<String> answerThenHang(FakeAdbdSession session, void Function() onOpened, {String text = ''}) async {
  var open = await session.receive();
  while (open.command != AdbCommand.open) {
    open = await session.receive();
  }
  session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
  if (text.isNotEmpty) session.send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: utf8.encode(text)));
  onOpened();
  while (true) {
    final m = await session.receive();
    // The client's own id comes first in what it sends.
    if (m.command == AdbCommand.close && m.arg0 == open.arg0) break;
  }
  return utf8.decode(open.payload).replaceAll('\u0000', '');
}

Future<AdbConnection> connectWith(FakeAdbd adbd, FakeClock clock) => AdbConnection.connect(
  adbd.address,
  adbd.port,
  key: testKey,
  clock: clock,
  options: const AdbConnectOptions(livenessInterval: null),
);

void main() {
  group('deadlines and limits', () {
    test('a silent service times out, its stream is closed, the connection still works', () async {
      final clock = FakeClock();
      final opened = Completer<void>();
      final hung = Completer<String>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        hung.complete(await answerThenHang(session, opened.complete));
        var open = await session.receive();
        while (open.command != AdbCommand.open) {
          open = await session.receive();
        }
        session
          ..send(AdbMessage.okay(localId: 10, remoteId: open.arg0))
          ..send(AdbMessage.write(localId: 10, remoteId: open.arg0, data: utf8.encode('remount succeeded\n')))
          ..send(AdbMessage.close(localId: 10, remoteId: open.arg0));
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      final adb = await connectWith(adbd, clock);
      final call = adb.daemon.remount(timeout: const Duration(seconds: 5));
      await opened.future;
      clock.advance(const Duration(seconds: 4));
      clock.advance(const Duration(seconds: 1));
      await expectLater(call, throwsA(isA<AdbTimeoutException>()));
      expect(await hung.future, 'remount:');
      expect(adb.isClosed, isFalse);
      expect((await adb.daemon.remount()).outcome, AdbDaemonOutcome.done);
      await adb.close();
      await adbd.done();
    });

    test('silence after a recognised answer is that answer', () async {
      final clock = FakeClock();
      final opened = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        await answerThenHang(session, opened.complete, text: answers['root: (production)']!);
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      final adb = await connectWith(adbd, clock);
      final call = adb.daemon.root(timeout: const Duration(seconds: 5));
      await opened.future;
      // The answer has to arrive before the deadline passes.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      clock.advance(const Duration(seconds: 5));
      expect((await call).outcome, AdbDaemonOutcome.refused);
      expect(adb.isClosed, isFalse);
      await adb.close();
      await adbd.done();
    });

    test('a restart announced without closing the stream ends the connection at the deadline', () async {
      final clock = FakeClock();
      final opened = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        var open = await session.receive();
        while (open.command != AdbCommand.open) {
          open = await session.receive();
        }
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: open.arg0))
          ..send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: utf8.encode(answers['tcpip:5555']!)));
        opened.complete();
        await session
            .receive(timeout: const Duration(seconds: 3))
            .catchError((Object _) => AdbMessage.close(localId: 0, remoteId: 0));
        session.destroy();
      });
      final adb = await connectWith(adbd, clock);
      final call = adb.daemon.tcpip(5555, timeout: const Duration(seconds: 5));
      await opened.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      clock.advance(const Duration(seconds: 5));
      expect((await call).restarting, isTrue);
      expect(adb.isClosed, isTrue);
      await adbd.done();
    });

    test('output past the limit is a command error and closes the stream', () async {
      final closed = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        var open = await session.receive();
        while (open.command != AdbCommand.open) {
          open = await session.receive();
        }
        session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        // Two payloads of 1 MiB would need acknowledgements; the first plus one byte is enough.
        session.send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: List.filled(1024 * 1024, 0x61)));
        while (true) {
          final m = await session.receive();
          if (m.command == AdbCommand.close) break;
          if (m.command == AdbCommand.okay) {
            session.send(AdbMessage.write(localId: 9, remoteId: open.arg0, data: [0x61]));
          }
        }
        closed.complete();
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
      await expectLater(
        adb.daemon.remount(),
        throwsA(isA<AdbCommandException>().having((e) => e.command, 'command', 'remount:')),
      );
      await closed.future.timeout(const Duration(seconds: 5));
      await adb.close();
      await adbd.done();
    });

    test('a device without the service: not supported', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        final open = await session.receive();
        session.send(AdbMessage.close(localId: 0, remoteId: open.arg0));
        await session.expectClientClose(timeout: const Duration(seconds: 2)).catchError((Object _) {});
      });
      final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
      await expectLater(adb.daemon.disableVerity(), throwsA(isA<AdbNotSupportedException>()));
      await adb.close();
      await adbd.done();
    });

    test('a reboot that never answers still ends the connection', () async {
      final clock = FakeClock();
      final opened = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        final open = await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        opened.complete();
        // The client drops the connection without draining, so its CLSE may or may not arrive.
        try {
          while (true) {
            await session.receive();
          }
        } on FakeAdbdFailure {
          session.destroy();
        }
      });
      final adb = await connectWith(adbd, clock);
      final call = adb.daemon.reboot();
      await opened.future;
      clock.advance(const Duration(seconds: 10));
      expect((await call).restarting, isTrue);
      expect(adb.isClosed, isTrue);
      await adbd.done();
    });

    test('every service asks for its own name', () async {
      for (final (name, run) in <(String, Future<AdbDaemonAnswer> Function(AdbConnection))>[
        ('unroot:', (a) => a.daemon.unroot()),
        ('usb:', (a) => a.daemon.usb()),
        ('disable-verity:', (a) => a.daemon.disableVerity()),
        ('enable-verity:', (a) => a.daemon.enableVerity()),
      ]) {
        final (adb, adbd, service) = await serve('some answer\n');
        final answer = await run(adb);
        expect(await service.future, name);
        expect(answer.output, 'some answer\n');
        expect('$answer', contains('some answer'));
        await adb.close();
        await adbd.done();
      }
    });
  });

  group('daemon answers (recorded)', () {
    test('root on a production build: refused, connection kept', () async {
      final (adb, adbd, service) = await serve(answers['root: (production)']!);
      final answer = await adb.daemon.root();
      expect(await service.future, 'root:');
      expect(answer.outcome, AdbDaemonOutcome.refused);
      expect(adb.isClosed, isFalse);
      await adb.close();
      await adbd.done();
    });

    test('root on userdebug: restarting, connection closed', () async {
      final (adb, adbd, _) = await serve(answers['root: (userdebug)']!);
      final answer = await adb.daemon.root();
      expect(answer.restarting, isTrue);
      expect(adb.isClosed, isTrue);
      await adbd.done();
    });

    test('tcpip cut off before the stream closed still restarts', () async {
      final (adb, adbd, service) = await serve(answers['tcpip:5555']!, closeStream: false);
      final answer = await adb.daemon.tcpip(5555);
      expect(await service.future, 'tcpip:5555');
      expect(answer.outcome, AdbDaemonOutcome.restarting);
      expect(answer.output, contains('restarting in TCP mode port: 5555'));
      await adbd.done();
    });

    test('remount refusals are refused, with the text', () async {
      final (adb, adbd, _) = await serve(answers['remount: (phone, locked)']!);
      final answer = await adb.daemon.remount();
      expect(answer.outcome, AdbDaemonOutcome.refused);
      expect(answer.output, 'Device must be bootloader unlocked\n');
      await adb.close();
      await adbd.done();

      final (adb2, adbd2, _) = await serve(answers['enable-verity: (TV, user build)']!);
      expect((await adb2.daemon.enableVerity()).outcome, AdbDaemonOutcome.refused);
      await adb2.close();
      await adbd2.done();

      final (adb3, adbd3, _) = await serve('remount succeeded\n');
      expect((await adb3.daemon.remount()).outcome, AdbDaemonOutcome.done);
      await adb3.close();
      await adbd3.done();
    });

    test('reboot on a closed connection says so', () async {
      final (adb, adbd, _) = await serve('remount succeeded\n');
      await adb.daemon.remount();
      await adb.close();
      await expectLater(adb.daemon.reboot(), throwsA(isA<AdbException>()));
      await adbd.done();
    });

    test('reboot ends the connection', () async {
      final (adb, adbd, service) = await serve('', closeStream: false);
      final answer = await adb.daemon.reboot('recovery');
      expect(await service.future, 'reboot:recovery');
      expect(answer.restarting, isTrue);
      expect(adb.isClosed, isTrue);
      await adbd.done();
    });

    test('bad arguments are refused before anything is sent', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        await session.expectQuiet(const Duration(milliseconds: 50));
        await session.expectClientClose();
      });
      final adb = await AdbConnection.connect(adbd.address, adbd.port, key: testKey);
      expect(() => adb.daemon.tcpip(0), throwsArgumentError);
      expect(() => adb.daemon.reboot('bad target;'), throwsArgumentError);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await adb.close();
      await adbd.done();
    });
  });

  group('waitFor', () {
    test('retries while adbd is not up yet, then connects', () async {
      var attempts = 0;
      final adbd = await FakeAdbd.start(connections: 3, (session) async {
        attempts++;
        if (attempts < 3) {
          // Still starting: the socket opens and closes.
          session.destroy();
          return;
        }
        await acceptHandshake(session, banner: classicBanner);
        await session.expectClientClose();
      });
      final notes = <String>[];
      final adb = await AdbConnection.waitFor(
        adbd.address,
        adbd.port,
        key: testKey,
        timeout: const Duration(seconds: 10),
        tracer: (e) {
          if (e is AdbNoteTrace && e.message.startsWith('waitFor')) {
            notes.add(e.message);
          }
        },
      );
      expect(attempts, 3);
      expect(notes, hasLength(2));
      await adb.close();
      await adbd.done();
    });

    test('gives up after the timeout with the last failure', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final watch = Stopwatch()..start();
      await expectLater(
        AdbConnection.waitFor('127.0.0.1', port, key: testKey, timeout: const Duration(milliseconds: 700)),
        throwsA(isA<AdbRefusedException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a device that refuses the key fails at once', () async {
      final adbd = await FakeAdbd.start((session) async {
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        await session.expectClientClose();
      });
      await expectLater(
        AdbConnection.waitFor(
          adbd.address,
          adbd.port,
          key: testKey,
          options: const AdbConnectOptions(allowPrompt: false),
        ),
        throwsA(isA<AdbUnauthorizedException>()),
      );
      await adbd.done();
    });

    test('cancel stops waiting', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final cancel = Completer<void>();
      Timer(const Duration(milliseconds: 300), cancel.complete);
      await expectLater(
        AdbConnection.waitFor('127.0.0.1', port, key: testKey, cancelOn: cancel.future),
        throwsA(isA<AdbCancelledException>()),
      );
    });
  });
}
