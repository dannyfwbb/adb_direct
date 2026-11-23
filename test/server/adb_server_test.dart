// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

String frame(String text) => '${utf8.encode(text).length.toRadixString(16).padLeft(4, '0')}$text';

/// A fake adb server: [answer] gets each request (in order on one socket) and returns what to send back, or null to
/// hand the socket to [raw].
Future<ServerSocket> fakeServer(String? Function(String request) answer, {void Function(Socket socket)? raw}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final buffer = <int>[];
    var rawMode = false;
    socket.listen(
      (data) {
        if (rawMode) return;
        buffer.addAll(data);
        while (buffer.length >= 4) {
          final n = int.parse(ascii.decode(buffer.sublist(0, 4)), radix: 16);
          if (buffer.length < 4 + n) break;
          final request = utf8.decode(buffer.sublist(4, 4 + n));
          buffer.removeRange(0, 4 + n);
          final reply = answer(request);
          if (reply == null) {
            rawMode = true;
            raw!(socket);
            return;
          }
          socket.write(reply);
        }
      },
      onError: (Object _) {},
      onDone: socket.destroy,
    );
  });
  return server;
}

void main() {
  test('version, devices-l and a refusal with its message', () async {
    final server = await fakeServer(
      (r) => switch (r) {
        'host:version' => 'OKAY${frame('0029')}',
        'host:devices-l' =>
          'OKAY${frame('emulator-5554          device product:sdk model:Pixel_10 '
          'device:emu transport_id:1\n192.168.0.20:5555      unauthorized transport_id:3\n')}',
        _ => 'FAIL${frame('unknown host service')}',
      },
    );
    final client = AdbServer(port: server.port);
    expect(await client.version(), 0x29);
    final devices = await client.devices();
    expect(devices.map((d) => (d.serial, d.state)), [
      ('emulator-5554', 'device'),
      ('192.168.0.20:5555', 'unauthorized'),
    ]);
    expect(devices.first.model, 'Pixel_10');
    expect(devices.first.properties['transport_id'], '1');
    await expectLater(
      client.disconnect('x'),
      throwsA(
        isA<AdbServiceUnavailableException>().having((e) => e.message, 'message', contains('unknown host service')),
      ),
    );
    await server.close();
  });

  test('connect: success and failure messages', () async {
    final server = await fakeServer(
      (r) => r.contains('192.168.0.20')
          ? 'OKAY${frame('connected to 192.168.0.20:5555')}'
          : 'OKAY${frame('failed to connect to 192.168.0.21:5555')}',
    );
    final client = AdbServer(port: server.port);
    expect(await client.connect('192.168.0.20'), contains('connected'));
    await expectLater(client.connect('192.168.0.21'), throwsA(isA<AdbUnreachableException>()));
    await server.close();
  });

  test('a device connection: transport, then the service, raw bytes', () async {
    final requests = <String>[];
    final server = await fakeServer(
      (r) {
        requests.add(r);
        if (r == 'host-serial:emulator-5554:features') return 'OKAY${frame('shell_v2,cmd')}';
        if (r == 'host:devices-l') return 'OKAY${frame('emulator-5554 device model:X\n')}';
        if (r == 'host:transport:emulator-5554') return 'OKAY';
        if (r == 'host:track-devices-l') return 'OKAY${frame('emulator-5554 device model:X\n')}';
        if (r.startsWith('exec:')) return null;
        return 'FAIL${frame('closed')}';
      },
      raw: (socket) {
        socket
          ..write('OKAY')
          ..add(utf8.encode('hello from the device'));
        unawaited(socket.close());
      },
    );
    final adb = await AdbServer(port: server.port).device('emulator-5554');
    expect(adb.device.model, 'X');
    expect(adb.supports(AdbFeature.shellV2), isTrue);
    final stream = await adb.open('exec:echo');
    expect(utf8.decode(await stream.input.expand((b) => b).toList()), 'hello from the device');
    expect(requests, containsAllInOrder(['host:transport:emulator-5554', 'exec:echo']));
    await expectLater(adb.open('jdwp:1'), throwsA(isA<AdbServiceUnavailableException>()));
    await adb.close();
    expect(adb.isClosed, isTrue);
    await server.close();
  });

  group('relayed streams', () {
    /// A server for `emulator-5554` whose tracking socket stays open; `exec:` sockets go to [raw].
    Future<(ServerSocket, List<Socket>)> relay(void Function(StreamSubscription<List<int>> input) raw) async {
      final trackers = <Socket>[];
      late ServerSocket server;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        final buffer = <int>[];
        var taken = false;
        // It ends with the socket.
        // ignore: cancel_subscriptions
        late StreamSubscription<List<int>> sub;
        sub = socket.listen(
          (data) {
            if (taken) return;
            buffer.addAll(data);
            while (buffer.length >= 4) {
              final n = int.parse(ascii.decode(buffer.sublist(0, 4)), radix: 16);
              if (buffer.length < 4 + n) return;
              final r = utf8.decode(buffer.sublist(4, 4 + n));
              buffer.removeRange(0, 4 + n);
              if (r == 'host-serial:emulator-5554:features') {
                socket.write('OKAY${frame('shell_v2')}');
              } else if (r == 'host:devices-l') {
                socket.write('OKAY${frame('emulator-5554 device model:X\n')}');
              } else if (r == 'host:transport:emulator-5554') {
                socket.write('OKAY');
              } else if (r == 'host:track-devices-l') {
                socket.write('OKAY${frame('emulator-5554 device model:X\n')}');
                trackers.add(socket);
              } else if (r.startsWith('exec:')) {
                taken = true;
                socket.write('OKAY');
                sub.onData(null);
                raw(sub);
                return;
              } else {
                socket.write('FAIL${frame('closed')}');
              }
            }
          },
          onError: (Object _) {},
          onDone: socket.destroy,
        );
      });
      return (server, trackers);
    }

    test('writes reach the service and count as acknowledged', () async {
      final got = Completer<String>();
      final bytes = <int>[];
      final (server, _) = await relay((input) {
        input.onData((d) {
          bytes.addAll(d);
          if (bytes.length >= 5 && !got.isCompleted) got.complete(ascii.decode(bytes));
        });
      });
      final adb = await AdbServer(port: server.port).device('emulator-5554');
      final stream = await adb.open('exec:cat');
      final acks = <int>[];
      final sub = stream.acknowledgements.listen(acks.add);
      await stream.write(ascii.encode('he'));
      await stream.write(const []);
      await stream.write(ascii.encode('llo'));
      await stream.flush();
      expect(await got.future.timeout(const Duration(seconds: 5)), 'hello');
      expect(stream.acknowledgedBytes, 5);
      expect(acks, [2, 5]);
      await sub.cancel();
      await stream.close();
      expect(stream.isClosed, isTrue);
      await expectLater(stream.write([1]), throwsA(isA<AdbCancelledException>()));
      await adb.close();
      await server.close();
    });

    test('a write blocked on a server that stopped reading ends when the stream closes', () async {
      // Never reads: the socket buffers fill up and the flush stays pending.
      final (server, _) = await relay((input) => input.pause());
      final adb = await AdbServer(port: server.port).device('emulator-5554');
      final stream = await adb.open('exec:cat');
      final pending = stream.write(Uint8List(64 * 1024 * 1024)).then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stream.close();
      final outcome = await pending.timeout(const Duration(seconds: 5), onTimeout: () => 'STILL PENDING');
      expect(outcome, isNot('STILL PENDING'));
      await adb.close();
      await server.close();
    });

    test('losing the server ends the connection and its streams', () async {
      final (server, trackers) = await relay((_) {});
      final adb = await AdbServer(port: server.port).device('emulator-5554');
      final stream = await adb.open('exec:cat');
      final failed = expectLater(stream.input.drain<void>(), throwsA(isA<AdbClosedException>()));
      while (trackers.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      trackers.single.destroy();
      await adb.done.timeout(const Duration(seconds: 5));
      await failed;
      expect(adb.closeReason, isA<AdbClosedException>());
      expect(() => adb.openStream('exec:x'), throwsA(isA<AdbClosedException>()));
      await server.close();
    });

    test('what the server cannot give: reverse handlers in code; connection facts', () async {
      final (server, _) = await relay((_) {});
      final adb = await AdbServer(port: server.port).device('emulator-5554');
      await expectLater(adb.reverse.add('tcp:1', (stream) {}), throwsA(isA<AdbNotSupportedException>()));
      expect(adb.acceptedKey, isNull);
      expect(adb.isTls, isFalse);
      expect(adb.deviceCertificate, isNull);
      expect(adb.delayedAck, isFalse);
      expect(adb.maxPayload, 0xffff);
      expect(adb.protocolVersion, 0x01000001);
      await adb.close();
      await server.close();
    });
  });

  test('closing a device connection at once, with the server gone, reports nothing', () async {
    final errors = <Object>[];
    final done = Completer<void>();
    unawaited(
      runZonedGuarded<Future<void>>(() async {
        final server = await fakeServer(
          (r) => switch (r) {
            'host-serial:emulator-5554:features' => 'OKAY${frame('shell_v2')}',
            'host:devices-l' => 'OKAY${frame('emulator-5554 device model:X\n')}',
            _ => 'FAIL${frame('closed')}',
          },
        );
        final adb = await AdbServer(port: server.port).device('emulator-5554');
        await server.close();
        await adb.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        done.complete();
      }, (e, _) => errors.add(e)),
    );
    await done.future.timeout(const Duration(seconds: 5));
    expect(errors, isEmpty);
  });

  test('no server: refused', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await expectLater(AdbServer(port: port).version(), throwsA(isA<AdbRefusedException>()));
  });

  test('tracking stays open while nothing changes (past the timeout)', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) async {
      socket.write('OKAY${frame('a device\n')}');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      socket.write(frame('b device\n'));
    });
    final lists = await AdbServer(
      port: server.port,
      timeout: const Duration(milliseconds: 200),
    ).trackDevices().take(2).toList();
    expect(lists.map((l) => l.single.serial), ['a', 'b']);
    await server.close();
  });

  test('a device that leaves ends its connection; unauthorized is said', () async {
    Socket? tracker;
    final server = await fakeServer(
      (r) {
        if (r == 'host:devices-l') return 'OKAY${frame('s1 device model:X\ns2 unauthorized\n')}';
        if (r == 'host-serial:s1:features') return 'OKAY${frame('shell_v2')}';
        if (r == 'host:track-devices-l') return null;
        return 'FAIL${frame('device unauthorized')}';
      },
      raw: (socket) {
        tracker = socket;
        socket.write('OKAY${frame('s1 device\n')}');
      },
    );
    final client = AdbServer(port: server.port);
    await expectLater(client.device('s2'), throwsA(isA<AdbUnauthorizedException>()));
    final adb = await client.device('s1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(adb.isClosed, isFalse);
    tracker!.write(frame('s1 offline\n'));
    await adb.done.timeout(const Duration(seconds: 2));
    expect(adb.closeReason, isA<AdbClosedException>());
    await server.close();
  });

  test('device lines: "no permissions" and properties', () {
    final d = AdbServerDevice.parse('0123ABC no permissions (user in plugdev group) usb:1-1 transport_id:4');
    expect(d.state, 'no permissions');
    expect(d.properties['usb'], '1-1');
  });
}
