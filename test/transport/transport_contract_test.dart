// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/connection/message_link.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../../example/usb_transport_outline.dart';

final class _RecordingTransport implements AdbTransport {
  final List<Uint8List> writes = [];

  @override
  int get pendingWriteBytes => 0;

  @override
  void start(AdbTransportListener listener) {}

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  @override
  Future<void> close({required Duration drainTimeout}) async {}

  @override
  void destroy() {}

  @override
  Future<X509Certificate?> startTls({required SecurityContext context, void Function(String line)? keyLog}) =>
      throw UnimplementedError();
}

final class _Pipe implements UsbBulkPipe {
  final List<int> transfers = [];

  @override
  int get maxPacketSize => 512;

  @override
  Future<Uint8List> read(int maxLength) async => Uint8List(0);

  @override
  Future<void> write(Uint8List data) async => transfers.add(data.length);

  @override
  Future<void> close() async {}
}

Future<List<int>> _framed(int payload) async {
  final pipe = _Pipe();
  final transport = UsbTransport(pipe)..write(Uint8List(24 + payload));
  await Future<void>.delayed(Duration.zero);
  expect(transport.pendingWriteBytes, 0);
  return pipe.transfers;
}

void main() {
  test('each write carries one whole message', () {
    final transport = _RecordingTransport();
    MessageLink(transport, clock: AdbClock.system)
      ..send(AdbMessage.okay(localId: 1, remoteId: 2))
      ..send(AdbMessage.write(localId: 1, remoteId: 2, data: Uint8List(100)));
    expect(transport.writes.map((w) => w.length), [24, 124]);
  });

  group('the USB outline', () {
    test('a message without payload is one transfer', () async {
      expect(await _framed(0), [24]);
    });

    test('header and payload are separate transfers', () async {
      expect(await _framed(100), [24, 100]);
    });

    test('a payload that fills its last packet ends with a zero-length packet', () async {
      expect(await _framed(1024), [24, 1024, 0]);
    });
  });
}
