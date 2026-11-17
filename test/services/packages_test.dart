// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:adb_direct/src/services/packages.dart'
    show pmFailure, pmSessionId;
import 'package:test/test.dart';

import '../connection/streams_test.dart' show connectTo, noLiveness;
import '../support/adbd_scripts.dart' show classicBanner, oldBanner;
import '../support/fake_adbd.dart';
import '../support/fake_clock.dart';

/// A device with `abb_exec` (Android 11+).
final Uint8List abbBanner = utf8.encode(
  '${utf8.decode(classicBanner)},cmd,abb_exec',
);

/// A device with `cmd` but no `abb_exec` (Android 7-10).
final Uint8List cmdBanner = utf8.encode('${utf8.decode(classicBanner)},cmd');

/// adbd's side of one package manager command: accepts the OPEN, reads
/// [expectInput] bytes of stdin (acknowledging), answers [output], closes.
Future<String> command(
  FakeAdbdSession session, {
  required String output,
  int expectInput = 0,
  int deviceId = 30,
}) async {
  var open = await session.receive();
  while (open.command != AdbCommand.open) {
    open = await session.receive();
  }
  final service = utf8.decode(open.payload).replaceAll(RegExp(r'\x00$'), '');
  session.send(AdbMessage.okay(localId: deviceId, remoteId: open.arg0));
  var received = 0;
  while (received < expectInput) {
    final message = await session.receive();
    if (message.command != AdbCommand.write) continue;
    received += message.payload.length;
    session.send(AdbMessage.okay(localId: deviceId, remoteId: open.arg0));
  }
  session
    ..send(
      AdbMessage.write(
        localId: deviceId,
        remoteId: open.arg0,
        data: utf8.encode(output),
      ),
    )
    ..send(AdbMessage.close(localId: deviceId, remoteId: open.arg0));
  return service;
}

final AdbApk tiny = AdbApk.bytes('base.apk', List.filled(10, 1));

void main() {
  group('how commands reach the package manager', () {
    test('abb_exec: arguments separated by NUL, no shell quoting', () async {
      late String service;
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        service = await command(session, output: 'Success\n', expectInput: 10);
      });
      await adb.packages.install(
        tiny,
        options: const AdbInstallOptions(grantPermissions: true, user: 0),
      );
      expect(
        service,
        'abb_exec:package\u0000install\u0000-r\u0000-g\u0000--user\u0000'
        '0\u0000-S\u000010',
      );
      await adbd.done();
      await adb.close();
    });

    test('cmd: exec:cmd package with quoted arguments', () async {
      late String service;
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        service = await command(session, output: 'Success\n');
      });
      await adb.packages.uninstall("it's odd", keepData: true, user: 10);
      expect(service, "exec:cmd package uninstall -k --user 10 'it'\\''s odd'");
      await adbd.done();
      await adb.close();
    });

    test(
      'old devices: push to a temporary file, pm install, remove it',
      () async {
        final services = <String>[];
        final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
          // The push (sync) is answered by a minimal sync peer.
          final open = await session.receive();
          services.add(utf8.decode(open.payload));
          session.send(AdbMessage.okay(localId: 40, remoteId: open.arg0));
          final sent = BytesBuilder();
          while (true) {
            final message = await session.receive();
            if (message.command != AdbCommand.write) continue;
            sent.add(message.payload);
            session.send(AdbMessage.okay(localId: 40, remoteId: open.arg0));
            final bytes = sent.toBytes();
            if (bytes.length >= 8 &&
                String.fromCharCodes(
                      bytes.sublist(bytes.length - 8, bytes.length - 4),
                    ) ==
                    'DONE') {
              break;
            }
          }
          session.send(
            AdbMessage.write(
              localId: 40,
              remoteId: open.arg0,
              data: [...'OKAY'.codeUnits, 0, 0, 0, 0],
            ),
          );
          services
            ..add(await command(session, output: 'Success\n', deviceId: 41))
            ..add(await command(session, output: '', deviceId: 42));
        });
        await adb.packages.install(tiny);
        expect(services[0], 'sync:\u0000');
        final path = RegExp(
          r'^shell:pm install -r (/data/local/tmp/adb_direct_[0-9a-f]+\.apk)$',
        ).firstMatch(services[1])!.group(1)!;
        expect(services[2], contains('rm -f $path'));
        await adbd.done();
        await adb.close();
      },
    );
  });

  group('answers', () {
    Future<Object?> installAnswering(String output) async {
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        await command(session, output: output, expectInput: 10);
      });
      Object? error;
      try {
        await adb.packages.install(tiny);
      } on AdbInstallException catch (e) {
        error = e;
      }
      await adbd.done();
      await adb.close();
      return error;
    }

    test('Success', () async {
      expect(await installAnswering('Success\n'), isNull);
    });

    test('Failure [CODE: message]', () async {
      final error = await installAnswering(
        'Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]\n',
      );
      expect(
        error,
        isA<AdbInstallException>()
            .having(
              (e) => e.failureCode,
              'code',
              'INSTALL_FAILED_VERSION_DOWNGRADE',
            )
            .having((e) => e.output, 'output', contains('Downgrade detected')),
      );
    });

    test('Failure [CODE]', () async {
      final error = await installAnswering(
        'Failure [DELETE_FAILED_INTERNAL_ERROR]\n',
      );
      expect(
        (error! as AdbInstallException).failureCode,
        'DELETE_FAILED_INTERNAL_ERROR',
      );
    });

    test('anything else (a stack trace) keeps the text, no code', () async {
      final error = await installAnswering(
        "\nException occurred while executing 'install':\n"
        'java.lang.IllegalArgumentException: Unknown package\n',
      );
      expect(
        error,
        isA<AdbInstallException>()
            .having((e) => e.failureCode, 'code', isNull)
            .having((e) => e.output, 'output', contains('Unknown package')),
      );
    });

    test(
      'an exit status of 0 is not trusted: no Success, no success',
      () async {
        expect(await installAnswering(''), isA<AdbInstallException>());
      },
    );
  });

  group('sessions', () {
    test('create, write each APK, commit', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        services
          ..add(
            await command(
              session,
              output: 'Success: created install session [1234567]\n',
            ),
          )
          ..add(
            await command(
              session,
              output: 'Success: streamed 10 bytes\n',
              expectInput: 10,
            ),
          )
          ..add(
            await command(
              session,
              output: 'Success: streamed 4 bytes\n',
              expectInput: 4,
            ),
          )
          ..add(await command(session, output: 'Success\n'));
      });
      final progress = <int>[];
      await adb.packages.installMultiple([
        tiny,
        AdbApk.bytes('split_extra.apk', [1, 2, 3, 4]),
      ], onProgress: (done, total) => progress.add(done));
      expect(services, [
        'exec:cmd package install-create -r -S 14',
        'exec:cmd package install-write -S 10 1234567 base.apk -',
        'exec:cmd package install-write -S 4 1234567 split_extra.apk -',
        'exec:cmd package install-commit 1234567',
      ]);
      expect(progress.last, 14);
      await adbd.done();
      await adb.close();
    });

    test('a failed commit abandons the session', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        services
          ..add(
            await command(
              session,
              output: 'Success: created install session [7]\n',
            ),
          )
          ..add(await command(session, output: 'Success\n', expectInput: 10))
          ..add(
            await command(
              session,
              output: 'Failure [INSTALL_FAILED_MISSING_SPLIT: Missing split]\n',
            ),
          )
          ..add(await command(session, output: 'Success\n'));
      });
      await expectLater(
        adb.packages.installMultiple([tiny]),
        throwsA(
          isA<AdbInstallException>().having(
            (e) => e.failureCode,
            'code',
            'INSTALL_FAILED_MISSING_SPLIT',
          ),
        ),
      );
      expect(services.last, 'exec:cmd package install-abandon 7');
      await adbd.done();
      await adb.close();
    });

    test('several apps at once need at least cmd', () async {
      final (adb, adbd) = await connectTo(banner: oldBanner, (session) async {
        await session.expectQuiet(const Duration(milliseconds: 50));
      });
      await expectLater(
        adb.packages.installMultiPackage([
          [tiny],
        ]),
        throwsA(isA<AdbNotSupportedException>()),
      );
      await adbd.done();
      await adb.close();
    });
  });

  group('timing', () {
    test('an upload nothing acknowledges fails as a stall', () async {
      final clock = FakeClock();
      final (adb, adbd) = await connectTo(
        banner: abbBanner,
        clock: clock,
        options: noLiveness,
        (session) async {
          final open = await session.receive();
          session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
          await session.receive(); // the APK, never acknowledged
          // The watchdog notices within 1.25 × the stall timeout.
          clock.advance(const Duration(seconds: 40));
          while (true) {
            final message = await session.receive();
            if (message.command == AdbCommand.open) {
              session.send(
                AdbMessage.close(localId: 0, remoteId: message.arg0),
              );
              continue;
            }
            expect(message.command, AdbCommand.close);
            break;
          }
        },
      );
      await expectLater(
        adb.packages.install(AdbApk.bytes('a.apk', List.filled(10, 1))),
        throwsA(isA<AdbTimeoutException>()),
      );
      await adbd.done();
      await adb.close();
    });

    test(
      'the package manager may take minutes to answer, not forever',
      () async {
        final clock = FakeClock();
        final (adb, adbd) = await connectTo(
          banner: abbBanner,
          clock: clock,
          options: noLiveness,
          (session) async {
            final open = await session.receive();
            session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
            await session.receive();
            session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
            await Future<void>.delayed(const Duration(milliseconds: 50));
            clock.advance(const Duration(minutes: 4));
            await session.expectQuiet(const Duration(milliseconds: 50));
            clock.advance(const Duration(minutes: 2));
            while (true) {
              final message = await session.receive();
              if (message.command == AdbCommand.open) {
                session.send(
                  AdbMessage.close(localId: 0, remoteId: message.arg0),
                );
                continue;
              }
              expect(message.command, AdbCommand.close);
              break;
            }
          },
        );
        await expectLater(
          adb.packages.install(tiny),
          throwsA(isA<AdbTimeoutException>()),
        );
        await adbd.done();
        await adb.close();
      },
    );

    test('an APK that yields another size than announced is refused', () async {
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        final open = await session.receive();
        session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
        await session.receive();
        session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
        var message = await session.receive();
        while (message.command == AdbCommand.okay) {
          message = await session.receive();
        }
        expect(message.command, AdbCommand.close);
      });
      await expectLater(
        adb.packages.install(
          AdbApk(name: 'x.apk', size: 20, open: () => Stream.value([1, 2])),
        ),
        throwsArgumentError,
      );
      await adbd.done();
      await adb.close();
    });
  });

  group('recorded answers (test/fixtures/pm)', () {
    String answer(String name) =>
        File('test/fixtures/pm/$name.txt').readAsStringSync();

    test('successes', () {
      for (final name in [
        'install_abandon',
        'uninstall_success',
        'uninstall_other_user',
        'install_create',
      ]) {
        expect(pmFailure(answer(name), 'x'), isNull, reason: name);
      }
      expect(pmSessionId(answer('install_create')), isPositive);
      expect(
        pmSessionId('linker: warning\nSuccess: created install session [42]\n'),
        42,
      );
      expect(pmSessionId('Failure [INSTALL_FAILED_INTERNAL_ERROR]'), isNull);
    });

    test('failures with and without a code', () {
      expect(
        pmFailure(answer('install_downgrade'), 'x')!.failureCode,
        'INSTALL_FAILED_VERSION_DOWNGRADE',
      );
      expect(
        pmFailure(answer('uninstall_not_installed'), 'x')!.failureCode,
        'DELETE_FAILED_INTERNAL_ERROR',
      );
      final trace = pmFailure(answer('stack_trace'), 'x')!;
      expect(trace.failureCode, isNull);
      expect(trace.output, contains('Unknown package'));
    });
  });

  group('more sessions', () {
    test('abb_exec sessions: NUL-separated create, write, commit', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
        services
          ..add(
            await command(
              session,
              output: 'Success: created install session [5]\n',
            ),
          )
          ..add(await command(session, output: 'Success\n', expectInput: 10))
          ..add(await command(session, output: 'Success\n'));
      });
      await adb.packages.installMultiple([tiny]);
      expect(services, [
        'abb_exec:package\u0000install-create\u0000-r\u0000-S\u000010',
        'abb_exec:package\u0000install-write\u0000-S\u000010\u00005\u0000base.apk\u0000-',
        'abb_exec:package\u0000install-commit\u00005',
      ]);
      await adbd.done();
      await adb.close();
    });

    test('several apps: parent, children, add-session, commit', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        services
          ..add(
            await command(
              session,
              output: 'Success: created install session [100]\n',
            ),
          )
          ..add(
            await command(
              session,
              output: 'Success: created install session [101]\n',
            ),
          )
          ..add(await command(session, output: 'Success\n', expectInput: 10))
          ..add(
            await command(
              session,
              output: 'Success: created install session [102]\n',
            ),
          )
          ..add(await command(session, output: 'Success\n', expectInput: 10))
          ..add(await command(session, output: 'Success\n'))
          ..add(await command(session, output: 'Success\n'));
      });
      await adb.packages.installMultiPackage([
        [tiny],
        [AdbApk.bytes('other.apk', List.filled(10, 2))],
      ]);
      expect(services, [
        'exec:cmd package install-create --multi-package -r',
        'exec:cmd package install-create -r -S 10',
        'exec:cmd package install-write -S 10 101 base.apk -',
        'exec:cmd package install-create -r -S 10',
        'exec:cmd package install-write -S 10 102 other.apk -',
        'exec:cmd package install-add-session 100 101 102',
        'exec:cmd package install-commit 100',
      ]);
      await adbd.done();
      await adb.close();
    });

    test('a failed write abandons children and parent', () async {
      final services = <String>[];
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        services
          ..add(
            await command(
              session,
              output: 'Success: created install session [100]\n',
            ),
          )
          ..add(
            await command(
              session,
              output: 'Success: created install session [101]\n',
            ),
          )
          ..add(
            await command(
              session,
              output: 'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]\n',
              expectInput: 10,
            ),
          )
          ..add(await command(session, output: 'Success\n'))
          ..add(await command(session, output: 'Success\n'));
      });
      await expectLater(
        adb.packages.installMultiPackage([
          [tiny],
        ]),
        throwsA(
          isA<AdbInstallException>().having(
            (e) => e.failureCode,
            'code',
            'INSTALL_FAILED_INSUFFICIENT_STORAGE',
          ),
        ),
      );
      expect(services.sublist(3), [
        'exec:cmd package install-abandon 101',
        'exec:cmd package install-abandon 100',
      ]);
      await adbd.done();
      await adb.close();
    });

    test('a device without sessions is reported as not supported', () async {
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        await command(
          session,
          output: 'Error: unknown command \'install-create\'\n',
        );
      });
      await expectLater(
        adb.packages.installMultiple([tiny]),
        throwsA(isA<AdbNotSupportedException>()),
      );
      await adbd.done();
      await adb.close();
    });

    test(
      'a lost connection mid-upload fails the install, nothing unhandled',
      () async {
        final (adb, adbd) = await connectTo(banner: abbBanner, (session) async {
          final open = await session.receive();
          session.send(AdbMessage.okay(localId: 30, remoteId: open.arg0));
          await session.receive();
          session.destroy();
        });
        await expectLater(
          adb.packages.install(AdbApk.bytes('a.apk', List.filled(10, 1))),
          throwsA(isA<AdbException>()),
        );
        await adbd.done();
      },
    );
  });

  test(
    "Android 7's silent install-commit is a success over cmd only",
    () async {
      final (adb, adbd) = await connectTo(banner: cmdBanner, (session) async {
        await command(
          session,
          output: 'Success: created install session [5]\n',
        );
        await command(
          session,
          output: 'Success: streamed 10 bytes\n',
          expectInput: 10,
        );
        await command(session, output: '');
      });
      await adb.packages.installMultiple([tiny]);
      await adbd.done();
      await adb.close();

      final (adb2, adbd2) = await connectTo(banner: abbBanner, (session) async {
        await command(
          session,
          output: 'Success: created install session [5]\n',
        );
        await command(session, output: 'Success\n', expectInput: 10);
        await command(session, output: '');
        await command(session, output: 'Success\n'); // abandon
      });
      await expectLater(
        adb2.packages.installMultiple([tiny]),
        throwsA(isA<AdbInstallException>()),
      );
      await adbd2.done();
      await adb2.close();
    },
  );
}
