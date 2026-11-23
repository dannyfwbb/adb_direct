// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/services/answers.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

/// Recorded answers (test/fixtures/services/answers.json).
final Map<String, String> answers =
    (jsonDecode(File('test/fixtures/services/answers.json').readAsStringSync()) as Map<String, Object?>)
        .cast<String, String>();

Future<(AdbConnection, FakeAdbd)> connectTo(
  Future<void> Function(FakeAdbdSession session) script, {
  bool delayedAck = false,
}) async {
  final adbd = await FakeAdbd.start((session) async {
    await acceptHandshake(session, banner: delayedAck ? tvBanner : classicBanner);
    await script(session);
  });
  final adb = await AdbConnection.connect(
    adbd.address,
    adbd.port,
    key: testKey,
    options: const AdbConnectOptions(livenessInterval: null),
  );
  return (adb, adbd);
}

/// The next message [where] accepts, skipping others (acknowledgements of earlier answers).
Future<AdbMessage> next(FakeAdbdSession session, bool Function(AdbMessage m) where) async {
  while (true) {
    final m = await session.receive();
    if (where(m)) return m;
  }
}

/// adbd's side of a one-shot service: accepts the next OPEN, answers [answer], closes. Returns the service name.
Future<String> answer(FakeAdbdSession session, String answer, {int deviceId = 40, int? window}) async {
  var open = await session.receive();
  while (open.command != AdbCommand.open) {
    open = await session.receive();
  }
  session
    ..send(AdbMessage.okay(localId: deviceId, remoteId: open.arg0, acknowledged: window))
    ..send(AdbMessage.write(localId: deviceId, remoteId: open.arg0, data: latin1.encode(answer)))
    ..send(AdbMessage.close(localId: deviceId, remoteId: open.arg0));
  return utf8.decode(open.payload).replaceAll('\u0000', '');
}

void main() {
  group('smart socket answers (recorded)', () {
    test('OKAY with and without text, FAIL with text', () {
      final port = SmartAnswer.parse(latin1.encode(answers['reverse:forward:tcp:0;tcp:19001']!));
      expect((port.ok, port.text), (true, '42277'));
      final bare = SmartAnswer.parse(latin1.encode(answers['reverse:killforward-all']!));
      expect((bare.ok, bare.text), (true, ''));
      final fail = SmartAnswer.parse(latin1.encode(answers['reverse:forward:bogus;tcp:1']!));
      expect(fail.ok, isFalse);
      expect(fail.text, contains('unknown socket specification'));
      expect(() => SmartAnswer.parse(latin1.encode('OKAY00ff12')), throwsA(isA<AdbProtocolException>()));
      expect(() => SmartAnswer.parse(latin1.encode('NOPE')), throwsA(isA<AdbProtocolException>()));
      // Signs and spaces are no hex digits.
      for (final bad in ['OKAY-001x', 'OKAY+0011', 'OKAY 001x']) {
        expect(() => SmartAnswer.parse(latin1.encode(bad)), throwsA(isA<AdbProtocolException>()), reason: bad);
      }
    });
  });

  group('reverse', () {
    test('tcp:0 gets its port; list parses the device lines', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo((session) async {
        services
          ..add(await answer(session, answers['reverse:forward:tcp:0;tcp:19001']!))
          ..add(await answer(session, answers['reverse:list-forward']!));
      });
      final forward = await adb.reverse.toLocalPort('tcp:0', 19001);
      expect(forward.deviceSpec, 'tcp:42277');
      expect(forward.devicePort, 42277);
      expect(services.first, 'reverse:forward:tcp:0;tcp:19001');
      expect(await adb.reverse.list(), const [
        AdbReverseEntry('tcp:18080', 'tcp:19000'),
        AdbReverseEntry('tcp:42277', 'tcp:19001'),
        AdbReverseEntry('tcp:18081', 'localabstract:whatever'),
      ]);
      await adbd.done();
      await adb.close();
    });

    test('a refusal is AdbServiceUnavailableException with the text', () async {
      final (adb, adbd) = await connectTo((session) async {
        await answer(session, answers['reverse:forward:norebind:tcp:18080;tcp:19002']!);
      });
      await expectLater(
        adb.reverse.add('tcp:18080', (_) {}, rebind: false),
        throwsA(isA<AdbServiceUnavailableException>().having((e) => e.message, 'message', contains('cannot rebind'))),
      );
      await adbd.done();
      await adb.close();
    });

    test('device connections: accepted for our forward, refused otherwise, '
        'with our window under delayed acknowledgements', () async {
      final got = Completer<String>();
      final (adb, adbd) = await connectTo(delayedAck: true, (session) async {
        final service = await answer(session, 'OKAY000518080', window: 1 << 20);
        final label = service.split(';').last;
        // Something else: refused with CLSE(0, id).
        session.send(AdbMessage.open(localId: 70, service: 'tcp:22', window: 1 << 20));
        final refused = await next(session, (m) => m.arg1 == 70);
        expect(refused.command, AdbCommand.close);
        expect((refused.arg0, refused.arg1), (0, 70));
        // Our label: accepted, our window in the OKAY.
        session.send(AdbMessage.open(localId: 71, service: label, window: 1 << 20));
        final okay = await next(session, (m) => m.arg1 == 71);
        expect(okay.command, AdbCommand.okay);
        expect(okay.arg1, 71);
        expect(okay.payload, hasLength(4));
        session.send(AdbMessage.write(localId: 71, remoteId: okay.arg0, data: [104, 105]));
        // The handler's answer, then our acknowledgement of "hi".
        final messages = [await session.receive(), await session.receive()];
        final write = messages.firstWhere((m) => m.command == AdbCommand.write);
        got.complete(utf8.decode(write.payload));
        session.send(AdbMessage.close(localId: 71, remoteId: okay.arg0));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      await adb.reverse.add('tcp:18080', (stream) {
        stream.input.listen((data) => stream.write([...data, 33]));
      });
      expect(await got.future, 'hi!');
      await adbd.done();
      await adb.close();
    });
  });

  group('forward', () {
    test('each local connection opens the service and copies both ways', () async {
      final (adb, adbd) = await connectTo((session) async {
        final open = await session.receive();
        expect(utf8.decode(open.payload), 'tcp:8080\u0000');
        session.send(AdbMessage.okay(localId: 50, remoteId: open.arg0));
        final write = await session.receive();
        expect(utf8.decode(write.payload), 'GET /\n');
        session
          ..send(AdbMessage.okay(localId: 50, remoteId: open.arg0))
          ..send(AdbMessage.write(localId: 50, remoteId: open.arg0, data: utf8.encode('200 OK\n')));
        await session.receive(); // our OKAY
        session.send(AdbMessage.close(localId: 50, remoteId: open.arg0));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      final forward = await adb.forward('tcp:8080');
      final socket = await Socket.connect('127.0.0.1', forward.port);
      socket.add(utf8.encode('GET /\n'));
      final reply = await utf8.decodeStream(socket);
      expect(reply, '200 OK\n');
      socket.destroy();
      await forward.close();
      await adbd.done();
      await adb.close();
    });

    test('closing the connection closes the forward', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expectClientClose();
      });
      final forward = await adb.forward('tcp:1');
      await adb.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(forward.isClosed, isTrue);
      await expectLater(Socket.connect('127.0.0.1', forward.port), throwsA(isA<SocketException>()));
      await adbd.done();
    });
  });

  group('reverse: the rest of it', () {
    test('a device that never answers: timeout, the target is released, the connection works', () async {
      final clock = FakeClock();
      final opened = Completer<void>();
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session, banner: classicBanner);
        final open = await next(session, (m) => m.command == AdbCommand.open);
        session.send(AdbMessage.okay(localId: 40, remoteId: open.arg0));
        opened.complete();
        await next(session, (m) => m.command == AdbCommand.close && m.arg0 == open.arg0);
        // The forward did not happen: a connection to its target is refused.
        final label = utf8.decode(open.payload).replaceAll('\u0000', '').split(';').last;
        session.send(AdbMessage.open(localId: 91, service: label));
        final refused = await next(session, (m) => m.arg1 == 91);
        expect(refused.command, AdbCommand.close);
      });
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        clock: clock,
        options: const AdbConnectOptions(livenessInterval: null),
      );
      final call = adb.reverse.add('tcp:1', (stream) => fail('must not be reached'));
      await opened.future;
      clock.advance(const Duration(seconds: 30));
      await expectLater(call, throwsA(isA<AdbTimeoutException>()));
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });

    test('toLocalPort copies both ways to the local socket', () async {
      final local = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      local.listen((socket) {
        socket.listen((data) {
          socket
            ..add(ascii.encode('echo:'))
            ..add(data);
          unawaited(socket.close());
        });
      });
      final (adb, adbd) = await connectTo((session) async {
        final service = await answer(session, 'OKAY');
        session.send(AdbMessage.open(localId: 92, service: service.split(';').last));
        final okay = await next(session, (m) => m.command == AdbCommand.okay && m.arg1 == 92);
        session.send(AdbMessage.write(localId: 92, remoteId: okay.arg0, data: ascii.encode('ping')));
        final got = <int>[];
        while (got.length < 'echo:ping'.length) {
          final m = await next(session, (m) => m.command == AdbCommand.write && m.arg1 == 92);
          got.addAll(m.payload);
          session.send(AdbMessage.okay(localId: 92, remoteId: okay.arg0));
        }
        expect(ascii.decode(got), 'echo:ping');
        session.send(AdbMessage.close(localId: 92, remoteId: okay.arg0));
      });
      await adb.reverse.toLocalPort('tcp:8', local.port);
      await adbd.done();
      await adb.close();
      await local.close();
    });

    test('toLocalPort with nothing listening closes the device side', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final (adb, adbd) = await connectTo((session) async {
        final service = await answer(session, 'OKAY');
        session.send(AdbMessage.open(localId: 93, service: service.split(';').last));
        await next(session, (m) => m.command == AdbCommand.close && m.arg1 == 93);
      });
      await adb.reverse.toLocalPort('tcp:9', port);
      await adbd.done();
      await adb.close();
    });

    test('remove through the forward, removeAll, and bad specs', () async {
      final services = <String>[];
      final removed = Completer<void>();
      final (adb, adbd) = await connectTo((session) async {
        for (var i = 0; i < 4; i++) {
          services.add(await answer(session, 'OKAY'));
        }
        await removed.future;
        // After removeAll the old target is not accepted.
        final label = services[2].split(';').last;
        session.send(AdbMessage.open(localId: 94, service: label));
        final refused = await next(session, (m) => m.arg1 == 94);
        expect(refused.command, AdbCommand.close);
      });
      final first = await adb.reverse.add('tcp:1', (stream) => stream.close());
      expect('$first', contains('tcp:1'));
      await first.remove();
      await adb.reverse.add('tcp:2', (stream) => stream.close());
      await adb.reverse.removeAll();
      removed.complete();
      await adbd.done();
      expect(services[1], 'reverse:killforward:tcp:1');
      expect(services[3], 'reverse:killforward-all');
      await expectLater(adb.reverse.add('', (stream) {}), throwsArgumentError);
      await expectLater(adb.reverse.add('tcp:1;x', (stream) {}), throwsArgumentError);
      await adb.close();
    });

    test('entries compare by value', () {
      const a = AdbReverseEntry('tcp:1', 'tcp:2');
      expect(a, const AdbReverseEntry('tcp:1', 'tcp:2'));
      expect(a.hashCode, const AdbReverseEntry('tcp:1', 'tcp:2').hashCode);
      expect(a, isNot(const AdbReverseEntry('tcp:1', 'tcp:3')));
      expect('$a', 'tcp:1 → tcp:2');
    });
  });

  group('reverse bookkeeping', () {
    /// A device that answers every reverse command with [answer] and then tries an OPEN for each label in [probe] (the
    /// client's labels are read from the forward commands), reporting what came back.
    test('a rebind, a removal and a failed removal: which targets the device may still reach', () async {
      final labels = <String>[];
      final verdicts = <String, String>{};
      final (adb, adbd) = await connectTo((session) async {
        // add twice on the same spec (rebind), then remove it, then a removal the device refuses on another spec.
        labels.add((await answer(session, 'OKAY')).split(';').last);
        labels.add((await answer(session, 'OKAY')).split(';').last);
        await answer(session, 'OKAY'); // killforward tcp:1000
        labels.add((await answer(session, 'OKAY')).split(';').last);
        await answer(session, "FAIL001alistener 'tcp:2000' not found");
        var id = 80;
        for (final label in labels) {
          session.send(AdbMessage.open(localId: id, service: label));
          final m = await next(session, (m) => m.arg1 == id);
          verdicts[label] = m.command == AdbCommand.okay ? 'accepted' : 'refused';
          if (m.command == AdbCommand.okay) {
            session.send(AdbMessage.close(localId: id, remoteId: m.arg0));
          }
          id++;
        }
      });
      await adb.reverse.add('tcp:1000', (_) {});
      await adb.reverse.add('tcp:1000', (_) {});
      await adb.reverse.remove('tcp:1000');
      await adb.reverse.add('tcp:2000', (_) {});
      await expectLater(adb.reverse.remove('tcp:2000'), throwsA(isA<AdbServiceUnavailableException>()));
      await adbd.done();
      expect(verdicts, {
        labels[0]: 'refused', // replaced by the rebind
        labels[1]: 'refused', // removed
        labels[2]: 'accepted', // the device kept it, so do we
      });
      await adb.close();
    });

    test('two local ports never share a target; a failing async handler closes its stream', () async {
      final services = <String>[];
      final closed = Completer<void>();
      final (adb, adbd) = await connectTo((session) async {
        for (var i = 0; i < 4; i++) {
          services.add(await answer(session, 'OKAY'));
        }
        final failing = await answer(session, 'OKAY');
        session.send(AdbMessage.open(localId: 90, service: failing.split(';').last));
        final okay = await next(session, (m) => m.arg1 == 90);
        expect(okay.command, AdbCommand.okay);
        final close = await next(session, (m) => m.command == AdbCommand.close && m.arg1 == 90);
        expect(close.arg0, okay.arg0);
        closed.complete();
      });
      await adb.reverse.toLocalPort('tcp:1', 3000);
      await adb.reverse.toLocalPort('tcp:2', 3000, host: '10.0.0.5');
      // An InternetAddress names itself by its address, and the loopback one is the default.
      await adb.reverse.toLocalPort('tcp:5', 3000, host: InternetAddress('10.0.0.6'));
      await adb.reverse.toLocalPort('tcp:6', 3000, host: InternetAddress.loopbackIPv4);
      expect(services, [
        'reverse:forward:tcp:1;tcp:3000',
        'reverse:forward:tcp:2;tcp:3000:10.0.0.5',
        'reverse:forward:tcp:5;tcp:3000:10.0.0.6',
        'reverse:forward:tcp:6;tcp:3000',
      ]);
      expect(() => adb.reverse.toLocalPort('tcp:7', 3000, host: 'a b'), throwsArgumentError);
      await adb.reverse.add('tcp:3', (stream) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('handler failed');
      });
      await closed.future.timeout(const Duration(seconds: 5));
      await adbd.done();
      await adb.close();
    });

    test('an OPEN without a window under delayed ACK is refused', () async {
      final (adb, adbd) = await connectTo(delayedAck: true, (session) async {
        final service = await answer(session, 'OKAY', window: 1 << 20);
        session.send(AdbMessage.open(localId: 95, service: service.split(';').last));
        final m = await next(session, (m) => m.arg1 == 95);
        expect((m.command, m.arg0), (AdbCommand.close, 0));
      });
      await adb.reverse.add('tcp:4', (_) {});
      await adbd.done();
      await adb.close();
    });
  });
}
