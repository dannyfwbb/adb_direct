// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/protocol/shell_protocol.dart';

import 'fake_adbd.dart';

/// What a fake shell command prints and how it exits.
typedef ShellAnswer = ({String stdout, String stderr, int exit});

/// Plays a device with shell protocol v2 that answers every `shell,v2,raw:<command>` with [answer] until the client
/// goes away. Every command is added to [commands].
Future<void> serveShellCommands(
  FakeAdbdSession session,
  ShellAnswer Function(String command) answer,
  List<String> commands,
) async {
  var deviceId = 100;
  while (true) {
    final AdbMessage message;
    try {
      message = await session.receive(timeout: const Duration(seconds: 30));
    } on FakeAdbdFailure {
      return;
    }
    if (message.command != AdbCommand.open) continue;
    final service = utf8.decode(message.payload).replaceAll('\u0000', '');
    const prefix = 'shell,v2,raw:';
    if (!service.startsWith(prefix)) throw FakeAdbdFailure('expected a shell v2 command, got "$service"');
    final command = service.substring(prefix.length);
    commands.add(command);
    final id = deviceId++;
    final reply = answer(command);
    session
      ..send(AdbMessage.okay(localId: id, remoteId: message.arg0))
      ..send(
        AdbMessage.write(
          localId: id,
          remoteId: message.arg0,
          data: [
            if (reply.stdout.isNotEmpty) ...ShellProtocol.encode(ShellPacketId.stdout, utf8.encode(reply.stdout)),
            if (reply.stderr.isNotEmpty) ...ShellProtocol.encode(ShellPacketId.stderr, utf8.encode(reply.stderr)),
            ...ShellProtocol.encode(ShellPacketId.exit, [reply.exit]),
          ],
        ),
      )
      ..send(AdbMessage.close(localId: id, remoteId: message.arg0));
  }
}

/// A successful answer that prints [stdout].
ShellAnswer printed(String stdout, {String stderr = '', int exit = 0}) => (stdout: stdout, stderr: stderr, exit: exit);
