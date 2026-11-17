// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(
  Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555',
);
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set '
          '(see test/device/README.md)'
    : null;

/// The test app (test/fixtures/apks); removed after every test.
const String package = 'app.adbdirect.testapp';

AdbApk apk(String name) => AdbApk.file(File('test/fixtures/apks/$name.apk'));

void main() {
  AdbConnection? connection;
  AdbConnection adb() => connection!;
  var sdk = 0;

  /// Install sessions came with Android 5 (API 21): before, the library
  /// says so.
  Future<bool> hasSessions() async {
    if (sdk >= 21) return true;
    await expectLater(
      adb().packages.installMultiple([apk('app-v2')]),
      throwsA(isA<AdbNotSupportedException>()),
    );
    markTestSkipped('no install sessions before API 21 (checked: refused)');
    return false;
  }

  Future<String> installedVersion() async => (await adb().shell.run(
    'dumpsys package $package | grep versionCode',
  )).stdoutText;

  setUpAll(() async {
    if (skip != null) return;
    connection = await AdbConnection.connect(
      host!,
      port,
      key: AdbKeyPair.fromPem(File(keyPath!).readAsStringSync()),
    );
    sdk = int.parse(
      (await connection!.shell.run(
        'getprop ro.build.version.sdk',
      )).stdoutText.trim(),
    );
  });
  tearDown(() async {
    await connection?.shell.run('pm uninstall $package');
  });
  tearDownAll(() async => connection?.close());

  test('install, reinstall, downgrade refused then allowed', () async {
    final progress = <int>[];
    await adb().packages.install(
      apk('app-v2'),
      onProgress: (done, _) => progress.add(done),
    );
    expect(await installedVersion(), contains('versionCode=2'));
    final size = File('test/fixtures/apks/app-v2.apk').lengthSync();
    expect(progress.last, size);
    expect(progress, everyElement(inInclusiveRange(0, size)));
    await adb().packages.install(apk('app-v2'));
    await expectLater(
      adb().packages.install(apk('app-v1')),
      throwsA(
        isA<AdbInstallException>().having(
          (e) => e.failureCode,
          'failureCode',
          'INSTALL_FAILED_VERSION_DOWNGRADE',
        ),
      ),
    );
    await adb().packages.install(
      apk('app-v1'),
      options: const AdbInstallOptions(allowDowngrade: true),
    );
    expect(await installedVersion(), contains('versionCode=1'));
  }, skip: skip);

  test('a base with a split in one session', () async {
    if (!await hasSessions()) return;
    await adb().packages.installMultiple([apk('app-v2'), apk('app-v2-extra')]);
    final paths = (await adb().shell.run('pm path $package')).stdoutText;
    expect(paths, contains('base.apk'));
    expect(paths, contains('split_extra.apk'));
  }, skip: skip);

  test(
    'a split without its base is refused ("Full install must include a base package")',
    () async {
      if (!await hasSessions()) return;
      // That the session is then abandoned is checked by the unit tests: this
      // device offers the shell user no way to list install sessions.
      await expectLater(
        adb().packages.installMultiple([apk('app-v2-extra')]),
        throwsA(
          isA<AdbInstallException>().having(
            (e) => e.failureCode,
            'failureCode',
            'INSTALL_FAILED_INVALID_APK',
          ),
        ),
      );
    },
    skip: skip,
  );

  test('a file that is not an APK', () async {
    await expectLater(
      adb().packages.install(AdbApk.bytes('junk.apk', List.filled(4096, 7))),
      throwsA(
        isA<AdbInstallException>().having(
          (e) => e.failureCode,
          'failureCode',
          anyOf(
            startsWith('INSTALL_PARSE_FAILED_'),
            'INSTALL_FAILED_INVALID_APK',
          ),
        ),
      ),
    );
  }, skip: skip);

  test('uninstall, and uninstall of an app that is not there', () async {
    await adb().packages.install(apk('app-v2'));
    await adb().packages.uninstall(package);
    expect(await installedVersion(), isEmpty);
    await expectLater(
      adb().packages.uninstall(package),
      throwsA(
        isA<AdbInstallException>().having(
          (e) => e.failureCode,
          'failureCode',
          // Android 9's pm prints a Java stack trace instead: no code.
          anyOf('DELETE_FAILED_INTERNAL_ERROR', isNull),
        ),
      ),
    );
  }, skip: skip);

  test('two apps atomically (multi-package)', () async {
    if (sdk < 29) {
      markTestSkipped('several apps atomically need Android 10');
      return;
    }
    await adb().packages.installMultiPackage([
      [apk('app-v2')],
    ]);
    expect(await installedVersion(), contains('versionCode=2'));
  }, skip: skip);
}
