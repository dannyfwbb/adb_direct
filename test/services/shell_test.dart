// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/protocol/shell_protocol.dart';
import 'package:test/test.dart';

import '../connection/streams_test.dart' show connectTo, noLiveness;
import '../support/adbd_scripts.dart' show oldBanner;
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';
import '../support/fixtures.dart';

const command = 'echo hi; echo err >&2; exit 3';

/// Accepts `OPEN` of a service starting with [prefix]; returns the device
/// id used (9) after answering OKAY.
Future<String> acceptOpen(FakeAdbdSession session, String prefix) async {
  final open = await session.receive();
  final service = utf8.decode(open.payload).replaceAll('\u0000', '');
  if (open.command != AdbCommand.open || !service.startsWith(prefix)) {
    throw FakeAdbdFailure('expected OPEN $prefix…, got $open "$service"');
  }
  session.send(AdbMessage.okay(localId: 9, remoteId: open.arg0));
  return service;
}

void main() {
  group('run with shell protocol v2', () {
    test('separates stdout and stderr and reports the exit status '
        '(recorded bytes)', () async {
      final recorded = Fixture.load(
        'shell/v2',
      ).fromDevice.firstWhere((m) => m.command == AdbCommand.write).payload;
      final (adb, adbd) = await connectTo((session) async {
        await acceptOpen(session, 'shell,v2,raw:$command');
        await session.expect(
          AdbMessage.write(
            localId: 1,
            remoteId: 9,
            data: ShellProtocol.encode(ShellPacketId.closeStdin, const []),
          ),
        );
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: recorded));
        await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
        session
          ..send(AdbMessage.close(localId: 9, remoteId: 1))
          ..send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      final result = await adb.shell.run(command);
      expect(result.stdoutText, 'hi\n');
      expect(result.stderrText, 'err\n');
      expect(result.exitCode, 3);
      expect(result.separateStreams, isTrue);
      expect(result.truncated, isFalse);
      await adbd.done();
      await adb.close();
    });

    test('packets split across writes are reassembled', () async {
      final packets = [
        ...ShellProtocol.encode(ShellPacketId.stdout, utf8.encode('abc')),
        ...ShellProtocol.encode(ShellPacketId.exit, [0]),
      ];
      final (adb, adbd) = await connectTo((session) async {
        await acceptOpen(session, 'shell,v2,raw:');
        await session.receive();
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        for (final byte in packets) {
          session.send(AdbMessage.write(localId: 9, remoteId: 1, data: [byte]));
          await session.receive();
        }
        session.send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      final result = await adb.shell.run('x');
      expect(result.stdoutText, 'abc');
      expect(result.exitCode, 0);
      await adbd.done();
      await adb.close();
    });

    test('output past the limit stops the command', () async {
      final (adb, adbd) = await connectTo((session) async {
        await acceptOpen(session, 'shell,v2,raw:');
        await session.receive();
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(
            AdbMessage.write(
              localId: 9,
              remoteId: 1,
              data: ShellProtocol.encode(
                ShellPacketId.stdout,
                utf8.encode('hello world'),
              ),
            ),
          );
        // The listener closes the stream as soon as the limit is reached,
        // inside delivery: no acknowledgement is needed any more.
        await session.expect(AdbMessage.close(localId: 1, remoteId: 9));
      });
      final result = await adb.shell.run('yes', maxOutputBytes: 5);
      expect(result.stdoutText, 'hello');
      expect(result.truncated, isTrue);
      expect(result.exitCode, isNull);
      await adbd.done();
      await adb.close();
    });

    test(
      'a command past its timeout is stopped; the connection lives on',
      () async {
        final clock = FakeClock();
        final (adb, adbd) = await connectTo(clock: clock, options: noLiveness, (
          session,
        ) async {
          await acceptOpen(session, 'shell,v2,raw:sleep');
          await session.receive();
          session.send(AdbMessage.okay(localId: 9, remoteId: 1));
          clock.advance(const Duration(seconds: 11));
          await session.expect(AdbMessage.close(localId: 1, remoteId: 9));
          // The OKAY for close-stdin may arrive after the stream closed;
          // the client then answers it with a second CLSE, as adb does.
        });
        await expectLater(
          adb.shell.run('sleep 100', timeout: const Duration(seconds: 10)),
          throwsA(isA<AdbTimeoutException>()),
        );
        await adbd.done();
        expect(adb.isClosed, isFalse);
        await adb.close();
      },
    );
  });

  group('run on devices without shell protocol v2', () {
    /// With [exec] the device has `exec:` (Android 5+); without, it refuses
    /// it and the command goes through `shell:` and its PTY.
    Future<AdbShellResult> runOld(
      String cmd,
      List<String> Function(String marker) chunks, {
      bool exec = true,
    }) async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        if (!exec) {
          final refused = await session.receive();
          expect(
            utf8.decode(refused.payload),
            startsWith('exec:exec </dev/null\n(\n$cmd\n)\necho '),
          );
          session.send(AdbMessage.close(localId: 0, remoteId: refused.arg0));
        }
        final service = await acceptOpen(
          session,
          '${exec ? 'exec' : 'shell'}:exec </dev/null\n(\n$cmd\n)\necho ',
        );
        final marker = RegExp(
          r'echo (ADB_DIRECT_EXIT_[0-9a-f]+_)\$\?$',
        ).firstMatch(service)!.group(1)!;
        final id = exec ? 1 : 2;
        for (final chunk in chunks(marker)) {
          session.send(
            AdbMessage.write(
              localId: 9,
              remoteId: id,
              data: utf8.encode(chunk),
            ),
          );
          await session.expect(AdbMessage.okay(localId: id, remoteId: 9));
        }
        session.send(AdbMessage.close(localId: 9, remoteId: id));
      });
      final result = await adb.shell.run(cmd);
      await adbd.done();
      await adb.close();
      return result;
    }

    test('learns the exit status from the marker', () async {
      final result = await runOld(
        'ls',
        (marker) => [
          'hi\nerr\n${marker.substring(0, 5)}',
          '${marker.substring(5)}3\n',
        ],
      );
      expect(result.stdoutText, 'hi\nerr\n');
      expect(result.exitCode, 3);
      expect(result.separateStreams, isFalse);
    });

    test('output without a final newline keeps its last line', () async {
      final result = await runOld(
        'printf x',
        (marker) => ['partial${marker}7\r\n'],
      );
      expect(result.stdoutText, 'partial');
      expect(result.exitCode, 7);
    });

    test('without exec: the PTY\'s CR LF line ends become LF', () async {
      final result = await runOld(
        'ls',
        (marker) => ['a\r\nb\r\n${marker}0\r\n'],
        exec: false,
      );
      expect(result.stdoutText, 'a\nb\n');
      expect(result.exitCode, 0);
    });

    test('no marker (the command exited the shell): status unknown', () async {
      final result = await runOld('exit 4', (marker) => ['bye\n']);
      expect(result.stdoutText, 'bye\n');
      expect(result.exitCode, isNull);
    });
  });

  test(
    'an interactive session: stdin, window size, output, exit status',
    () async {
      final (adb, adbd) = await connectTo((session) async {
        await acceptOpen(session, 'shell,v2,TERM=xterm-256color,pty:');
        await session.expect(
          AdbMessage.write(
            localId: 1,
            remoteId: 9,
            data: ShellProtocol.encode(
              ShellPacketId.stdin,
              utf8.encode('ls\n'),
            ),
          ),
        );
        session.send(AdbMessage.okay(localId: 9, remoteId: 1));
        await session.expect(
          AdbMessage.write(
            localId: 1,
            remoteId: 9,
            data: ShellProtocol.encode(
              ShellPacketId.windowSizeChange,
              utf8.encode('24x80,0x0'),
            ),
          ),
        );
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(
            AdbMessage.write(
              localId: 9,
              remoteId: 1,
              data: [
                ...ShellProtocol.encode(
                  ShellPacketId.stdout,
                  utf8.encode('a b\n'),
                ),
                ...ShellProtocol.encode(ShellPacketId.exit, [3]),
              ],
            ),
          );
        await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
        session.send(AdbMessage.close(localId: 9, remoteId: 1));
      });
      final shell = await adb.shell.start();
      final output = shell.stdout.toList();
      await shell.write(utf8.encode('ls\n'));
      await shell.resize(rows: 24, columns: 80);
      expect(await shell.exitCode, 3);
      expect(utf8.decode((await output).expand((b) => b).toList()), 'a b\n');
      await adbd.done();
      await adb.close();
    },
  );

  test('exec opens a raw stream', () async {
    final (adb, adbd) = await connectTo((session) async {
      await acceptOpen(session, 'exec:screencap -p');
      session
        ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [0x89, 0x50]))
        ..send(AdbMessage.close(localId: 9, remoteId: 1));
      await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
    });
    final stream = await adb.shell.exec('screencap -p');
    expect((await stream.input.toList()).expand((b) => b), [0x89, 0x50]);
    await adbd.done();
    await adb.close();
  });

  test('shellQuote', () {
    expect(shellQuote('plain-arg_1.txt'), 'plain-arg_1.txt');
    expect(shellQuote(''), "''");
    expect(shellQuote('two words'), "'two words'");
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(r'$HOME;rm -rf /'), r"'$HOME;rm -rf /'");
  });

  group('sessions on old devices and edge cases', () {
    test('without shell protocol v2: plain "shell:", always a PTY', () async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        await acceptOpen(session, 'shell:');
        session
          ..send(AdbMessage.write(localId: 9, remoteId: 1, data: [0x24, 0x20]))
          ..send(AdbMessage.close(localId: 9, remoteId: 1));
        await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
      });
      final shell = await adb.shell.start();
      expect(shell.shellProtocol, isFalse);
      expect((await shell.stdout.toList()).expand((b) => b), [0x24, 0x20]);
      expect(await shell.exitCode, isNull);
      await expectLater(
        adb.shell.start(command: 'wc -c', pty: false),
        throwsA(isA<AdbNotSupportedException>()),
      );
      await adbd.done();
      await adb.close();
    });

    test(
      'nothing is read from the device until stdout has a listener',
      () async {
        final (adb, adbd) = await connectTo((session) async {
          await acceptOpen(session, 'shell,v2,');
          session.send(
            AdbMessage.write(
              localId: 9,
              remoteId: 1,
              data: ShellProtocol.encode(ShellPacketId.stdout, [1]),
            ),
          );
          await session.expectQuiet(const Duration(milliseconds: 200));
          await session.expect(AdbMessage.okay(localId: 1, remoteId: 9));
          session.send(AdbMessage.close(localId: 9, remoteId: 1));
        });
        final shell = await adb.shell.start();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect((await shell.stdout.toList()).expand((b) => b), [1]);
        await adbd.done();
        await adb.close();
      },
    );

    test('a shell packet longer than adbd could send ends the run', () async {
      final (adb, adbd) = await connectTo((session) async {
        await acceptOpen(session, 'shell,v2,raw:');
        await session.receive();
        session
          ..send(AdbMessage.okay(localId: 9, remoteId: 1))
          ..send(
            AdbMessage.write(
              localId: 9,
              remoteId: 1,
              data: [1, 0xff, 0xff, 0xff, 0x7f],
            ),
          );
        await session.expect(AdbMessage.close(localId: 1, remoteId: 9));
      });
      await expectLater(
        adb.shell.run('x'),
        throwsA(isA<AdbProtocolException>()),
      );
      await adbd.done();
      await adb.close();
    });
  });
}
