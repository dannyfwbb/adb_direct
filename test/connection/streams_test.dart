// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/connection/connection.dart' show livenessService;
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

/// Starts a fake device with [banner] (classic flow control unless it lists
/// `delayed_ack`) running [script] after the handshake, and connects.
Future<(AdbConnection, FakeAdbd)> connectTo(
  Future<void> Function(FakeAdbdSession session) script, {
  Uint8List? banner,
  AdbClock clock = AdbClock.system,
  AdbConnectOptions options = const AdbConnectOptions(),
}) async {
  final adbd = await FakeAdbd.start((session) async {
    await acceptHandshake(session, banner: banner ?? classicBanner);
    await script(session);
  });
  final adb = await AdbConnection.connect(
    adbd.address,
    adbd.port,
    key: testKey,
    clock: clock,
    options: options,
  );
  return (adb, adbd);
}

/// Options for tests that move a fake clock and do not want the liveness
/// probe in their script.
const AdbConnectOptions noLiveness = AdbConnectOptions(livenessInterval: null);

AdbMessage open(int id, String service, {int window = 0}) =>
    AdbMessage.open(localId: id, service: service, window: window);

void main() {
  group('opening', () {
    test('OKAY opens; the device id is used from then on', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'shell:id'));
        session.send(AdbMessage.okay(localId: 77, remoteId: 1));
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 77, data: [1]),
        );
        session.send(AdbMessage.close(localId: 77, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('shell:id');
      await stream.write([1]);
      await stream.done;
      expect(stream.closeReason, isNull);
      await adb.close();
      await adbd.done();
    });

    test('CLSE(0, id) refuses the service', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'nosuchservice:'));
        session.send(AdbMessage.close(localId: 0, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      await expectLater(
        adb.open('nosuchservice:'),
        throwsA(
          isA<AdbServiceUnavailableException>().having(
            (e) => e.service,
            'service',
            'nosuchservice:',
          ),
        ),
      );
      expect(adb.isClosed, isFalse);
      await adb.close();
      await adbd.done();
    });

    test(
      'a stream closed while opening is closed when the device answers',
      () async {
        final (adb, adbd) = await connectTo((session) async {
          await session.expect(open(1, 'shell:'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          session.send(AdbMessage.okay(localId: 5, remoteId: 1));
          await session.expect(AdbMessage.close(localId: 1, remoteId: 5));
        });
        final stream = adb.openStream('shell:');
        final opened = expectLater(
          stream.opened,
          throwsA(isA<AdbCancelledException>()),
        );
        await stream.close();
        await opened;
        expect(stream.closeReason, isNull);
        await adbd.done();
        await adb.close();
      },
    );

    test('ids are allocated in order, starting at 1', () async {
      final (adb, adbd) = await connectTo((session) async {
        for (var id = 1; id <= 3; id++) {
          final message = await session.receive();
          expect(message.arg0, id);
          session.send(AdbMessage.okay(localId: 10 + id, remoteId: id));
        }
      });
      for (var i = 0; i < 3; i++) {
        await adb.open('x:');
      }
      await adbd.done();
      await adb.close();
    });
  });

  group('classic flow control', () {
    test('one write in flight; the next waits for OKAY', () async {
      final firstSeen = Completer<void>();
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'exec:cat'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 9, data: [1]),
        );
        firstSeen.complete();
        await session.expectQuiet(const Duration(milliseconds: 150));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 9, data: [2]),
        );
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1]);
      final second = stream.write([2]);
      await firstSeen.future;
      await second;
      await adbd.done();
      await adb.close();
    });

    test('data is acknowledged only when the listener takes it', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'shell:x'));
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [1]));
        // Nobody listens yet: no OKAY.
        await session.expectQuiet(const Duration(milliseconds: 150));
        await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
        session.send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      final stream = await adb.open('shell:x');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final received = await stream.input.toList();
      expect(received.expand((b) => b), [1]);
      await adbd.done();
      await adb.close();
    });

    test(
      'a paused listener holds the acknowledgement until it resumes',
      () async {
        final (adb, adbd) = await connectTo((session) async {
          await session.expect(open(1, 'shell:x'));
          session
            ..send(AdbMessage.okay(localId: 9, remoteId: 1))
            ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [1]));
          await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
          session.send(AdbMessage.write(localId: 9, remoteId: 1, data: [2]));
          await session.expectQuiet(const Duration(milliseconds: 150));
          await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
          session.send(AdbMessage.close(localId: 9, remoteId: 1));
        });
        final stream = await adb.open('shell:x');
        final got = <int>[];
        late StreamSubscription<Uint8List> subscription;
        subscription = stream.input.listen((data) {
          got.addAll(data);
          if (data.first == 1) {
            subscription.pause();
            Future<void>.delayed(
              const Duration(milliseconds: 250),
              subscription.resume,
            );
          }
        });
        await stream.done;
        await subscription.asFuture<void>();
        await subscription.cancel();
        expect(got, [1, 2]);
        await adbd.done();
        await adb.close();
      },
    );
  });

  group('delayed acknowledgements', () {
    test('windows in OPEN and OKAY, writes within the budget, '
        'acknowledged byte counts', () async {
      final window = const AdbConnectOptions().receiveWindow;
      final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
        await session.expect(open(1, 'exec:cat', window: window));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 6));
        // Budget 6: two writes of 3 go out without waiting.
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 9, data: [1, 1, 1]),
        );
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 9, data: [2, 2, 2]),
        );
        await session.expectQuiet(const Duration(milliseconds: 150));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 3));
        await session.expect(
          AdbMessage.write(localId: 1, remoteId: 9, data: [3, 3, 3]),
        );
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 6))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [5, 5]));
        await session.expect(
          AdbMessage.okay(localId: 1, remoteId: 9, acknowledged: 2),
        );
        session.send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      expect(adb.delayedAck, isTrue);
      final stream = await adb.open('exec:cat');
      final input = stream.input.toList();
      await Future.wait([
        stream.write([1, 1, 1]),
        stream.write([2, 2, 2]),
        stream.write([3, 3, 3]),
      ]);
      expect((await input).expand((b) => b), [5, 5]);
      await adbd.done();
      await adb.close();
    });

    test('an OPEN answer without a window is ignored, as adbd ignores a '
        'malformed OKAY', () async {
      final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
        await session.receive();
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 64));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('x:');
      expect(stream.isClosed, isFalse);
      await adbd.done();
      await adb.close();
    });
  });

  group('routing', () {
    test('duplicate and late messages are ignored; OKAY for an unknown '
        'stream is answered with CLSE', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'shell:x'));
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(AdbMessage.close(localId: 9, remoteId: 1))
          ..send(AdbMessage.close(localId: 9, remoteId: 1))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [1]))
          ..send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expect(AdbMessage.close(localId: 1, remoteId: 9));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('shell:x');
      await stream.done;
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });

    test(
      'a message from another device stream id does not reach the stream',
      () async {
        final (adb, adbd) = await connectTo((session) async {
          await session.expect(open(1, 'shell:x'));
          session
            ..send(AdbMessage.okay(localId: 9, remoteId: 1))
            ..send(AdbMessage.write(localId: 8, remoteId: 1, data: [9]))
            ..send(AdbMessage.close(localId: 8, remoteId: 1));
          await session.expectQuiet(const Duration(milliseconds: 150));
          session.send(AdbMessage.close(localId: 9, remoteId: 1));
        });
        final stream = await adb.open('shell:x');
        expect(await stream.input.toList(), isEmpty);
        await adbd.done();
        await adb.close();
      },
    );

    test('a device OPEN is refused', () async {
      final (adb, adbd) = await connectTo((session) async {
        session.send(
          AdbMessage(AdbCommand.open, 33, 0, utf8.encode('tcp:19000\u0000')),
        );
        await session.expect(AdbMessage.close(localId: 0, remoteId: 33));
      });
      await adbd.done();
      await adb.close();
    });

    test('a new CNXN ends the connection', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.receive();
        session.send(
          AdbMessage(
            AdbCommand.connect,
            AdbProtocol.version,
            4096,
            classicBanner,
          ),
        );
        await session.expectClientClose();
      });
      final stream = adb.openStream('shell:x');
      await adb.done;
      expect(adb.closeReason, isA<AdbClosedException>());
      await stream.done;
      expect(stream.closeReason, isA<AdbClosedException>());
      await adbd.done();
    });

    test('an unknown command is skipped', () async {
      final (adb, adbd) = await connectTo((session) async {
        final bytes = Uint8List(24);
        ByteData.sublistView(bytes)
          ..setUint32(0, 0x5a5a5a5a, Endian.little)
          ..setUint32(20, 0x5a5a5a5a ^ 0xffffffff, Endian.little);
        session.sendRaw(bytes);
        await session.expect(open(1, 'x:'));
        session.send(AdbMessage.close(localId: 0, remoteId: 1));
      });
      await expectLater(
        adb.open('x:'),
        throwsA(isA<AdbServiceUnavailableException>()),
      );
      await adbd.done();
      await adb.close();
    });
  });

  group('failures end everything', () {
    test('an overdue acknowledgement checks the device; no answer fails '
        'the connection (frozen device)', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (
        session,
      ) async {
        await session.expect(open(1, 'exec:cat'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive(); // the write, never acknowledged
        clock.advance(const Duration(seconds: 21));
        await session.expect(open(2, livenessService));
        clock.advance(const Duration(seconds: 21));
        await session.expectClientClose();
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1]);
      final second = expectLater(
        stream.write([2]),
        throwsA(isA<AdbTimeoutException>()),
      );
      await adb.done;
      await second;
      expect(adb.closeReason, isA<AdbTimeoutException>());
      expect(stream.closeReason, isA<AdbTimeoutException>());
      await expectLater(adb.open('x:'), throwsA(isA<AdbTimeoutException>()));
      await adbd.done();
    });

    test('a stalled stream on a healthy device does not end the connection '
        '(adbd holds OKAY while a process does not read)', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (
        session,
      ) async {
        await session.expect(open(1, 'shell:sleep 60'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive(); // never acknowledged: sleep reads nothing
        clock.advance(const Duration(seconds: 21));
        await session.expect(open(2, livenessService));
        session.send(AdbMessage.close(localId: 0, remoteId: 2));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('shell:sleep 60');
      await stream.write([1]);
      final second = expectLater(
        stream.write([2]),
        throwsA(isA<AdbCancelledException>()),
      );
      await adbd.done();
      expect(adb.isClosed, isFalse);
      expect(stream.isClosed, isFalse);
      await adb.close();
      await second;
    });

    test(
      'a device that never answers OPEN is checked, then given up',
      () async {
        final clock = FakeClock();
        final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (
          session,
        ) async {
          await session.receive();
          clock.advance(const Duration(seconds: 21));
          await session.expect(open(2, livenessService));
          clock.advance(const Duration(seconds: 21));
          await session.expectClientClose();
        });
        await expectLater(adb.open('x:'), throwsA(isA<AdbTimeoutException>()));
        await adbd.done();
      },
    );

    test(
      'a dropped socket fails streams, pending writes and the input',
      () async {
        final (adb, adbd) = await connectTo((session) async {
          await session.expect(open(1, 'exec:cat'));
          session.send(AdbMessage.okay(localId: 9, remoteId: 1));
          await session.receive();
          session.destroy();
        });
        final stream = await adb.open('exec:cat');
        final input = stream.input.toList();
        await stream.write([1]);
        final pending = stream.write([2]);
        await expectLater(pending, throwsA(isA<AdbClosedException>()));
        await expectLater(input, throwsA(isA<AdbClosedException>()));
        await stream.done;
        await adb.done;
        await adbd.done();
      },
    );

    test('closing the connection cancels pending work', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'exec:cat'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive();
        await session.expectClientClose();
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1]);
      final pending = expectLater(
        stream.write([2]),
        throwsA(isA<AdbCancelledException>()),
      );
      await adb.close();
      await pending;
      expect(adb.closeReason, isA<AdbCancelledException>());
      await adbd.done();
    });

    test('a service name longer than the payload limit is refused', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expectClientClose();
      });
      expect(() => adb.openStream('x' * (1 << 20)), throwsArgumentError);
      await adb.close();
      await adbd.done();
    });
  });

  group('liveness', () {
    test('silence on an open stream sends the ping; an answer keeps the '
        'connection', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, (session) async {
        await session.expect(open(1, 'shell:sleep 60'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 50));
        clock.advance(const Duration(seconds: 10));
        await session.expect(open(2, livenessService));
        session.send(AdbMessage.close(localId: 0, remoteId: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        clock.advance(const Duration(seconds: 25));
        await session.expect(open(3, livenessService));
        session.send(AdbMessage.close(localId: 0, remoteId: 3));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('shell:sleep 60');
      await adbd.done();
      expect(adb.isClosed, isFalse);
      expect(stream.isClosed, isFalse);
      await adb.close();
    });

    test(
      'a ping without an answer fails the connection (frozen device)',
      () async {
        final clock = FakeClock();
        final (adb, adbd) = await connectTo(clock: clock, (session) async {
          await session.expect(open(1, 'shell:sleep 60'));
          session.send(AdbMessage.okay(localId: 9, remoteId: 1));
          await session.expectQuiet(const Duration(milliseconds: 50));
          clock.advance(const Duration(seconds: 10));
          await session.expect(open(2, livenessService));
          clock.advance(const Duration(seconds: 21));
          await session.expectClientClose();
        });
        final stream = await adb.open('shell:sleep 60');
        final input = expectLater(
          stream.input.toList(),
          throwsA(isA<AdbTimeoutException>()),
        );
        await adb.done;
        expect(adb.closeReason, isA<AdbTimeoutException>());
        await input;
        await adbd.done();
      },
    );

    test('no streams, no ping', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(clock: clock, (session) async {
        // Let the client finish the handshake before time moves.
        await session.expectQuiet(const Duration(milliseconds: 100));
        clock.advance(const Duration(minutes: 5));
        await session.expectQuiet(const Duration(milliseconds: 150));
      });
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });
  });

  group('robustness', () {
    test('everything pending completes when the socket drops', () async {
      final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
        for (var i = 0; i < 4; i++) {
          await session.receive();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        session.destroy();
      });
      final run = adb.shell.run('sleep 100');
      final session = adb.shell.start();
      final opening = adb.openStream('exec:never');
      final queued = opening.write([1, 2, 3]);
      final closedWhileOpening = adb.openStream('exec:also');
      await closedWhileOpening.close();
      Future<Object?> outcome(Future<Object?> f) =>
          f.then<Object?>((v) => v, onError: (Object e) => e);
      final results = await Future.wait<Object?>([
        outcome(run),
        outcome(session),
        outcome(opening.opened.then((_) => 'opened')),
        outcome(queued.then((_) => 'written')),
        outcome(closedWhileOpening.done.then((_) => 'done')),
        outcome(adb.done.then((_) => 'connection done')),
      ]).timeout(const Duration(seconds: 5));
      expect(results[0], isA<AdbClosedException>());
      expect(results[1], isA<AdbClosedException>());
      expect(results[2], isA<AdbClosedException>());
      expect(results[3], isA<AdbClosedException>());
      expect(results[4], 'done');
      expect(results[5], 'connection done');
      await adbd.done();
    });

    test('a listener may close the stream from its data callback', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'shell:x'));
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [1]))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [2]));
        await session.expect(AdbMessage.close(localId: 1, remoteId: 9));
      });
      final stream = await adb.open('shell:x');
      final got = <int>[];
      final subscription = stream.input.listen((data) {
        got.addAll(data);
        unawaited(stream.close());
      });
      await stream.done;
      await subscription.cancel();
      expect(got, [1]);
      await adbd.done();
      expect(adb.isClosed, isFalse);
      await adb.close();
    });

    test(
      'delayed acknowledgements: a paused listener holds the OKAY',
      () async {
        final window = const AdbConnectOptions().receiveWindow;
        final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
          await session.expect(open(1, 'shell:x', window: window));
          session
            ..send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 100))
            ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [1, 1]))
            ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [2, 2, 2]));
          await session.expect(
            AdbMessage.okay(localId: 1, remoteId: 9, acknowledged: 2),
          );
          await session.expectQuiet(const Duration(milliseconds: 150));
          await session.expect(
            AdbMessage.okay(localId: 1, remoteId: 9, acknowledged: 3),
          );
          session.send(AdbMessage.close(localId: 9, remoteId: 1));
        });
        final stream = await adb.open('shell:x');
        late StreamSubscription<Uint8List> subscription;
        subscription = stream.input.listen((data) {
          if (data.first == 1) {
            subscription.pause();
            Future<void>.delayed(
              const Duration(milliseconds: 250),
              subscription.resume,
            );
          }
        });
        await stream.done;
        await subscription.cancel();
        await adbd.done();
        await adb.close();
      },
    );

    test('writes are split at the payload limit', () async {
      final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
        final o = await session.receive();
        session.send(
          AdbMessage.okay(localId: 9, remoteId: o.arg0, acknowledged: 1 << 30),
        );
        final sizes = <int>[];
        while (sizes.fold<int>(0, (a, b) => a + b) < 2621440) {
          sizes.add((await session.receive()).payload.length);
        }
        expect(sizes, [1048576, 1048576, 524288]);
      });
      final stream = await adb.open('exec:cat');
      await stream.write(Uint8List(2621440));
      await adbd.done();
      await adb.close();
    });

    test('a malformed OKAY to an OPEN is dropped, as adbd does', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'x:'));
        session
          ..send(AdbMessage(AdbCommand.okay, 9, 1, [1, 2]))
          ..send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final stream = await adb.open('x:');
      expect(stream.isClosed, isFalse);
      await adbd.done();
      await adb.close();
    });

    test('close() does not hang on a device that stopped reading', () async {
      final (adb, adbd) = await connectTo(
        options: const AdbConnectOptions(
          acknowledgementTimeout: Duration(milliseconds: 300),
          livenessInterval: null,
        ),
        banner: tvBanner,
        (session) async {
          final o = await session.receive();
          session.send(
            AdbMessage.okay(
              localId: 9,
              remoteId: o.arg0,
              acknowledged: 1 << 30,
            ),
          );
          // Read nothing more: the client's socket buffers fill up.
          await Future<void>.delayed(const Duration(seconds: 2));
        },
      );
      final stream = await adb.open('exec:cat');
      for (var i = 0; i < 64; i++) {
        unawaited(stream.write(Uint8List(1 << 20)).catchError((Object _) {}));
      }
      await adb.close().timeout(const Duration(seconds: 3));
      await adbd.done();
    });

    test('options that cannot work are refused', () async {
      for (final options in [
        const AdbConnectOptions(receiveWindow: 0),
        const AdbConnectOptions(receiveWindow: 0x80000000),
        const AdbConnectOptions(acknowledgementTimeout: Duration.zero),
        const AdbConnectOptions(livenessInterval: Duration(seconds: -1)),
      ]) {
        await expectLater(
          AdbConnection.connect('127.0.0.1', 1, key: testKey, options: options),
          throwsArgumentError,
        );
      }
    });
  });

  group('flush', () {
    test('classic: completes when the last write is acknowledged', () async {
      final acknowledged = Completer<void>();
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'exec:cat'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        acknowledged.complete();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1, 2, 3]);
      await stream.flush();
      expect(acknowledged.isCompleted, isTrue);
      expect(stream.acknowledgedBytes, 3);
      await adbd.done();
      await adb.close();
    });

    test('delayed ACK: completes when every byte is acknowledged', () async {
      final window = const AdbConnectOptions().receiveWindow;
      final (adb, adbd) = await connectTo(banner: tvBanner, (session) async {
        await session.expect(open(1, 'exec:cat', window: window));
        session.send(
          AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 100),
        );
        await session.receive();
        await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 2));
        await session.expectQuiet(const Duration(milliseconds: 50));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1, acknowledged: 3));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1, 1]);
      await stream.write([2, 2, 2]);
      var flushed = false;
      final flush = stream.flush().then((_) => flushed = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(stream.acknowledgedBytes, lessThan(5));
      expect(flushed, isFalse);
      await flush;
      expect(flushed, isTrue);
      expect(stream.acknowledgedBytes, 5);
      await adbd.done();
      await adb.close();
    });

    test('fails when the stream closes first', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.expect(open(1, 'exec:cat'));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive();
        session.send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      final stream = await adb.open('exec:cat');
      await stream.write([1]);
      await expectLater(stream.flush(), throwsA(isA<AdbException>()));
      await adbd.done();
      await adb.close();
    });
  });

  group('flush edge cases', () {
    test('nothing written: completes at once, even while opening', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.receive();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      final stream = adb.openStream('exec:cat');
      await stream.flush().timeout(const Duration(seconds: 1));
      await stream.opened;
      await stream.flush();
      await adbd.done();
      await adb.close();
    });

    test('a write queued before the open is flushed after it', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      final stream = adb.openStream('exec:cat');
      unawaited(stream.write([1]));
      await stream.flush().timeout(const Duration(seconds: 2));
      expect(stream.acknowledgedBytes, 1);
      await adbd.done();
      await adb.close();
    });

    test('a stream the caller closed cannot be flushed', () async {
      final (adb, adbd) = await connectTo((session) async {
        await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.receive();
      });
      final stream = await adb.open('exec:cat');
      await stream.close();
      await expectLater(stream.flush(), throwsA(isA<AdbException>()));
      await adbd.done();
      await adb.close();
    });
  });
}
