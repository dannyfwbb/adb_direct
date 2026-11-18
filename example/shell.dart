// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// An interactive shell, like `adb shell`, or one command, like `adb shell <command>`:
//
//   dart run example/shell.dart 192.168.0.20 5555            # interactive; exit with `exit`
//   dart run example/shell.dart 192.168.0.20 5555 ls -l /     # one command, its exit status
//   dart run example/shell.dart 192.168.0.20 5555 --log       # logcat until Ctrl-C

import 'dart:async';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: shell <host> <port> [--log | command…]');
    exitCode = 64;
    return;
  }
  final adb = await connect(args[0], args[1]);
  try {
    if (args.length > 2 && args[2] == '--log') {
      final done = Completer<void>();
      final log = adb.debug.logcat(arguments: ['-v', 'brief']).listen(print, onDone: done.complete);
      ProcessSignal.sigint.watch().first.then((_) => log.cancel()).then((_) => done.complete()).ignore();
      await done.future;
    } else if (args.length > 2) {
      final command = args.skip(2).map(shellQuote).join(' ');
      final result = await adb.shell.run(command, timeout: const Duration(minutes: 5));
      stdout.add(result.stdout);
      stderr.add(result.stderr);
      exitCode = result.exitCode ?? 1;
    } else {
      await interactive(adb);
    }
  } finally {
    await adb.close();
  }
}

Future<void> interactive(AdbConnection adb) async {
  final terminal = stdin.hasTerminal;
  final session = await adb.shell.start(pty: true);
  if (terminal) {
    stdin
      ..echoMode = false
      ..lineMode = false;
    await session.resize(rows: stdout.terminalLines, columns: stdout.terminalColumns);
  }
  final output = session.stdout.listen(stdout.add);
  final input = stdin.listen(session.write, onDone: session.closeStdin);
  final status = await session.exitCode;
  await output.cancel();
  await input.cancel();
  if (terminal) {
    stdin
      ..lineMode = true
      ..echoMode = true;
  }
  exitCode = status ?? 0;
}
