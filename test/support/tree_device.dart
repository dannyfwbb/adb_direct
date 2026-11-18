// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:adb_direct/src/protocol/byte_queue.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/protocol/shell_protocol.dart';
import 'package:adb_direct/src/protocol/sync_protocol.dart';

import 'fake_adbd.dart';

/// A device for directory pushes: answers shell v2 commands (exit status from [shellExit]) and sync v1 `SEND`s, and
/// records both in order, until the client goes away.
final class TreeDevice {
  TreeDevice({this.shellExit = _zero});

  static int _zero(String _) => 0;

  /// The exit status of a shell command.
  final int Function(String command) shellExit;

  /// `shell <command>`, `push <path> <mode>`, in order.
  final List<String> log = [];

  /// What was pushed, by path.
  final Map<String, Uint8List> files = {};

  Future<void> serve(FakeAdbdSession session) async {
    var nextId = 100;
    final syncBuffers = <int, ByteQueue>{};
    final remoteOf = <int, int>{};
    while (true) {
      final AdbMessage message;
      try {
        message = await session.receive(timeout: const Duration(seconds: 30));
      } on FakeAdbdFailure {
        return;
      }
      if (message.command == AdbCommand.open) {
        final service = utf8.decode(message.payload).replaceAll('\u0000', '');
        final id = nextId++;
        session.send(AdbMessage.okay(localId: id, remoteId: message.arg0));
        if (service.startsWith('shell,v2,raw:')) {
          final command = service.substring('shell,v2,raw:'.length);
          log.add('shell $command');
          session
            ..send(
              AdbMessage.write(
                localId: id,
                remoteId: message.arg0,
                data: ShellProtocol.encode(ShellPacketId.exit, [shellExit(command)]),
              ),
            )
            ..send(AdbMessage.close(localId: id, remoteId: message.arg0));
        } else if (service == 'sync:') {
          syncBuffers[id] = ByteQueue();
          remoteOf[id] = message.arg0;
        } else {
          throw FakeAdbdFailure('unexpected service "$service"');
        }
      } else if (message.command == AdbCommand.write) {
        final id = message.arg1;
        session.send(AdbMessage.okay(localId: id, remoteId: message.arg0));
        final buffer = syncBuffers[id];
        if (buffer == null) continue; // Shell stdin.
        buffer.add(message.payload);
        _sync(buffer, (bytes) => session.send(AdbMessage.write(localId: id, remoteId: remoteOf[id]!, data: bytes)));
      }
    }
  }

  // The push being received on a sync stream: path and data so far.
  String? _path;
  BytesBuilder? _data;

  void _sync(ByteQueue buffer, void Function(List<int>) reply) {
    while (buffer.length >= 8) {
      final id = buffer.peekUint32Le(0);
      final value = buffer.peekUint32Le(4);
      if (id == SyncId.send) {
        if (buffer.length < 8 + value) return;
        buffer.skip(8);
        final spec = utf8.decode(buffer.take(value));
        final comma = spec.lastIndexOf(',');
        _path = spec.substring(0, comma);
        _data = BytesBuilder();
        log.add('push $_path ${int.parse(spec.substring(comma + 1)).toRadixString(8)}');
      } else if (id == SyncId.data) {
        if (buffer.length < 8 + value) return;
        buffer.skip(8);
        _data!.add(buffer.take(value));
      } else if (id == SyncId.done) {
        buffer.skip(8);
        files[_path!] = _data!.takeBytes();
        reply(SyncRequest.header(SyncId.okay, 0));
      } else if (id == SyncId.quit) {
        buffer.skip(8);
      } else {
        throw FakeAdbdFailure('unexpected sync request ${SyncId.name(id)}');
      }
    }
  }
}
