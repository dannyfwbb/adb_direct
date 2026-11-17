// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/constants.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/adbd_scripts.dart';
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

int checksumField(Uint8List raw) =>
    ByteData.sublistView(raw).getUint32(16, Endian.little);

void main() {
  test('a trusted key: token, signature, CNXN; banner and features', () async {
    late AdbMessage cnxn;
    final adbd = await FakeAdbd.start((session) async {
      cnxn = await acceptHandshake(session);
      await session.expectClientClose();
    });
    final adb = await AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: testKey,
    );
    expect(adb.device.model, 'AOSP TV on x86');
    expect(adb.delayedAck, isTrue);
    expect(adb.protocolVersion, AdbProtocol.version);
    expect(adb.maxPayload, AdbProtocol.maxPayload);
    expect(adb.acceptedKey, testKey);
    await adb.close();
    await adbd.done();

    expect(cnxn.arg0, AdbProtocol.version);
    expect(cnxn.arg1, AdbProtocol.maxPayload);
    final banner = utf8.decode(cnxn.payload);
    expect(banner, startsWith('host::features='));
    expect(banner, isNot(contains('\u0000')));
    expect(hostBanner(cnxn).features, AdbConnectOptions.defaultHostFeatures);
  });

  test(
    'messages before the device CNXN carry checksums, later ones none',
    () async {
      late List<Uint8List> raw;
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session);
        await session.expect(
          AdbMessage.open(
            localId: 1,
            service: 'x:',
            window: AdbConnectOptions().receiveWindow,
          ),
        );
        session.send(AdbMessage.close(localId: 0, remoteId: 1));
        raw = session.receivedRaw;
        await session.expectClientClose();
      });
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
      );
      await expectLater(
        adb.open('x:'),
        throwsA(isA<AdbServiceUnavailableException>()),
      );
      await adb.close();
      await adbd.done();
      expect(checksumField(raw[0]), isNonZero, reason: 'CNXN');
      expect(checksumField(raw[1]), isNonZero, reason: 'AUTH signature');
      expect(checksumField(raw[2]), 0, reason: 'OPEN after negotiation');
    },
  );

  test('tries keys in order and reports the one accepted', () async {
    final adbd = await FakeAdbd.start((session) async {
      await acceptHandshake(session, trusted: [testKey.publicKey]);
      await session.expectClientClose();
    });
    final adb = await AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: otherKey,
      extraKeys: [testKey],
    );
    expect(adb.acceptedKey, testKey);
    await adb.close();
    await adbd.done();
  });

  test('an untrusted key without prompting fails and offers nothing', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive(); // CNXN
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive(); // signature
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        options: const AdbConnectOptions(allowPrompt: false),
      ),
      throwsA(isA<AdbUnauthorizedException>()),
    );
    await adbd.done();
  });

  test(
    'an untrusted key is offered with a NUL, and the user accepts',
    () async {
      var waiting = 0;
      final adbd = await FakeAdbd.start((session) async {
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        final offer = await session.receive();
        if (offer.arg0 != AdbAuthType.rsaPublicKey.value) {
          throw FakeAdbdFailure('expected the public key, got $offer');
        }
        if (offer.payload.last != 0 ||
            AdbPublicKey.parse(utf8.decode(offer.payload)) !=
                testKey.publicKey) {
          throw FakeAdbdFailure('bad public key payload');
        }
        session.send(
          AdbMessage(
            AdbCommand.connect,
            AdbProtocol.version,
            0x100000,
            tvBanner,
          ),
        );
        await session.expectClientClose();
      });
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        onWaitingForApproval: () => waiting++,
      );
      expect(waiting, 1);
      expect(adb.acceptedKey, testKey);
      await adb.close();
      await adbd.done();
    },
  );

  test('an offered key the user does not accept in time', () async {
    final clock = FakeClock();
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive(); // the public key
      await session.expectClientClose(timeout: const Duration(seconds: 10));
    });
    final connecting = AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: testKey,
      clock: clock,
      // Let the handshake start waiting before time moves on.
      onWaitingForApproval: () => Future<void>.delayed(
        const Duration(milliseconds: 50),
        () => clock.advance(const Duration(minutes: 2, seconds: 1)),
      ),
    );
    await expectLater(connecting, throwsA(isA<AdbUnauthorizedException>()));
    await adbd.done();
  });

  test('a device that refuses after the offer (a new token)', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(adbd.address, adbd.port, key: testKey),
      throwsA(isA<AdbUnauthorizedException>()),
    );
    await adbd.done();
  });

  test('a device without authentication answers CNXN with CNXN', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(
        AdbMessage(
          AdbCommand.connect,
          AdbProtocol.version,
          0x100000,
          classicBanner,
        ),
      );
      await session.expectClientClose();
    });
    final adb = await AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: testKey,
    );
    expect(adb.acceptedKey, isNull);
    expect(adb.delayedAck, isFalse);
    await adb.close();
    await adbd.done();
  });

  test('a TLS port is reported as not supported yet', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(AdbMessage.stls());
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(adbd.address, adbd.port, key: testKey),
      throwsA(isA<AdbNotSupportedException>()),
    );
    await adbd.done();
  });

  test('a silent device fails the handshake after its timeout', () async {
    final clock = FakeClock();
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      clock.advance(const Duration(seconds: 11));
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        clock: clock,
      ),
      throwsA(isA<AdbTimeoutException>()),
    );
    await adbd.done();
  });

  test('messages other than AUTH before CNXN are ignored', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session
        ..send(AdbMessage.okay(localId: 3, remoteId: 4))
        ..send(
          AdbMessage(
            AdbCommand.connect,
            AdbProtocol.version,
            0x100000,
            classicBanner,
          ),
        );
      await session.expectClientClose();
    });
    final adb = await AdbConnection.connect(
      adbd.address,
      adbd.port,
      key: testKey,
    );
    await adb.close();
    await adbd.done();
  });

  test('a token of the wrong size is a protocol error', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, [1, 2, 3]));
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(adbd.address, adbd.port, key: testKey),
      throwsA(isA<AdbProtocolException>()),
    );
    await adbd.done();
  });

  test(
    'an old device (version 1.0, 4 KiB) keeps checksums and small writes',
    () async {
      late List<AdbMessage> writes;
      late List<Uint8List> raw;
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(
          session,
          banner: oldBanner,
          version: AdbProtocol.versionMin,
          maxPayload: AdbProtocol.maxPayloadV1,
        );
        final open = await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        writes = [];
        for (var i = 0; i < 3; i++) {
          final write = await session.receive();
          writes.add(write);
          session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
        }
        raw = session.receivedRaw;
        session.send(AdbMessage.close(localId: 9, remoteId: open.arg0));
        await session.expectClientClose();
      });
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
      );
      expect(adb.maxPayload, 4096);
      expect(adb.delayedAck, isFalse);
      final stream = await adb.open('exec:cat');
      await stream.write(Uint8List(10000)..fillRange(0, 10000, 7));
      await stream.done;
      await adb.close();
      await adbd.done();
      expect(writes.map((w) => w.payload.length), [4096, 4096, 1808]);
      expect(checksumField(raw.last), isNonZero);
    },
  );

  test('a failing approval callback still closes the socket', () async {
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive();
      session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
      await session.receive();
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        onWaitingForApproval: () => throw StateError('UI gone'),
      ),
      throwsStateError,
    );
    await adbd.done();
  });

  test('messages that do not advance the handshake cannot extend it', () async {
    final clock = FakeClock();
    final adbd = await FakeAdbd.start((session) async {
      await session.receive();
      for (var i = 0; i < 4; i++) {
        clock.advance(const Duration(seconds: 3));
        session.send(AdbMessage.okay(localId: 3, remoteId: 4));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await session.expectClientClose();
    });
    await expectLater(
      AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        clock: clock,
      ),
      throwsA(isA<AdbTimeoutException>()),
    );
    await adbd.done();
  });

  group('cancelling a connection attempt', () {
    test('while "Allow debugging?" waits: at once, socket closed', () async {
      final adbd = await FakeAdbd.start((session) async {
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        await session.receive();
        session.send(AdbMessage.auth(AdbAuthType.token, randomToken()));
        await session.receive(); // the public key
        await session.expectClientClose(timeout: const Duration(seconds: 2));
      });
      final cancel = Completer<void>();
      final watch = Stopwatch()..start();
      final connecting = AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        cancelOn: cancel.future,
        onWaitingForApproval: cancel.complete,
      );
      await expectLater(connecting, throwsA(isA<AdbCancelledException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await adbd.done();
    });

    test('already cancelled: no connection is made', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var accepted = 0;
      server.listen((socket) {
        accepted++;
        socket.destroy();
      });
      await expectLater(
        AdbConnection.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          key: testKey,
          cancelOn: Future<void>.value(),
        ),
        throwsA(isA<AdbCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(accepted, 0);
      await server.close();
    });

    test('a TCP connect that hangs stops when cancelled', () async {
      // A listening socket that never accepts still completes the TCP
      // handshake, so use one that is full: backlog 0 and one waiting
      // client. Where that is not enough the connect simply succeeds and
      // the handshake is cancelled instead; either way it is cancelled.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final cancel = Completer<void>();
      Timer(const Duration(milliseconds: 100), cancel.complete);
      await expectLater(
        AdbConnection.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          key: testKey,
          cancelOn: cancel.future,
        ),
        throwsA(isA<AdbCancelledException>()),
      );
      await server.close();
    });

    test('after the connection is up, cancelling does nothing', () async {
      final adbd = await FakeAdbd.start((session) async {
        await acceptHandshake(session);
        await session.expectQuiet(const Duration(milliseconds: 100));
      });
      final cancel = Completer<void>();
      final adb = await AdbConnection.connect(
        adbd.address,
        adbd.port,
        key: testKey,
        cancelOn: cancel.future,
      );
      cancel.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adb.isClosed, isFalse);
      await adbd.done();
      await adb.close(drain: false);
    });
  });
}
