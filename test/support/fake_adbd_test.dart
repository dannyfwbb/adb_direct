// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import 'fake_adbd.dart';
import 'fixtures.dart';

/// Plays the recorder's side of [fixture] against [adbd] over a real socket and returns the messages the fake sent.
Future<List<AdbMessage>> _playRecorder(Fixture fixture, FakeAdbd adbd) async {
  final socket = await Socket.connect(adbd.address, adbd.port);
  final reader = AdbMessageReader();
  final received = <AdbMessage>[];
  final closed = Completer<void>();
  final subscription = socket.listen((data) {
    reader.add(data);
    for (final message in reader.drain()) {
      received.add(message);
    }
  }, onDone: closed.complete);
  for (final message in fixture.toDevice) {
    socket.add(AdbMessageCodec.encode(message, withChecksum: false));
  }
  await socket.flush();
  await adbd.done();
  await closed.future.timeout(const Duration(seconds: 5));
  await subscription.cancel();
  socket.destroy();
  return received;
}

void main() {
  test('every fixture replays against itself', () async {
    for (final name in Fixture.all()) {
      final fixture = Fixture.load(name);
      final adbd = await FakeAdbd.start(replay(fixture));
      final received = await _playRecorder(fixture, adbd);
      expect(received, fixture.fromDevice.toList(), reason: name);
    }
  });

  test('a message the script does not expect fails the fake', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.expect(AdbMessage.open(localId: 1, service: 'shell:id'));
    });
    final socket = await Socket.connect(adbd.address, adbd.port);
    socket.add(AdbMessageCodec.encode(AdbMessage.open(localId: 1, service: 'shell:ls'), withChecksum: false));
    await expectLater(adbd.done(), throwsA(isA<FakeAdbdFailure>()));
    socket.destroy();
  });

  test('a client that closes early fails a script waiting for it', () async {
    final adbd = await FakeAdbd.start((session) => session.receive());
    final socket = await Socket.connect(adbd.address, adbd.port);
    await socket.close();
    await expectLater(adbd.done(), throwsA(isA<FakeAdbdFailure>()));
    socket.destroy();
  });

  test('replay fails when the client sends more than was recorded', () async {
    final fixture = Fixture.load('streams/unknown_service');
    final adbd = await FakeAdbd.start(replay(fixture));
    final socket = await Socket.connect(adbd.address, adbd.port);
    for (final message in [...fixture.toDevice, AdbMessage.open(localId: 3, service: 'shell:')]) {
      socket.add(AdbMessageCodec.encode(message, withChecksum: false));
    }
    await expectLater(adbd.done(), throwsA(isA<FakeAdbdFailure>()));
    socket.destroy();
  });

  test('done reports connections that never came', () async {
    final adbd = await FakeAdbd.start((session) async {}, connections: 2);
    final socket = await Socket.connect(adbd.address, adbd.port);
    await expectLater(
      adbd.done(timeout: const Duration(milliseconds: 300)),
      throwsA(isA<FakeAdbdFailure>().having((f) => f.message, 'message', contains('expected 2 connection(s), got 1'))),
    );
    socket.destroy();
    await adbd.close();
  });

  test('the last messages of a script reach the client', () async {
    final adbd = await FakeAdbd.start((session) async {
      for (var id = 1; id <= 200; id++) {
        session.send(AdbMessage.close(localId: id, remoteId: id));
      }
    });
    final socket = await Socket.connect(adbd.address, adbd.port);
    final reader = AdbMessageReader();
    await for (final data in socket) {
      reader.add(data);
    }
    expect(reader.drain().length, 200);
    await adbd.done();
    socket.destroy();
  });

  test('signatures are matched by shape, not bytes', () {
    final recorded = AdbMessage(AdbCommand.auth, 2, 0, [1, 2, 3]);
    expect(recordedPacketMatcher(recorded, AdbMessage(AdbCommand.auth, 2, 0, [9])), isTrue);
    expect(recordedPacketMatcher(recorded, AdbMessage(AdbCommand.auth, 3, 0, [9])), isFalse);
  });
}
