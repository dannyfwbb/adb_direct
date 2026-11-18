// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

final String? host = Platform.environment['ADB_DIRECT_TEST_HOST'];
final int port = int.parse(Platform.environment['ADB_DIRECT_TEST_PORT'] ?? '5555');
final String? keyPath = Platform.environment['ADB_DIRECT_TEST_KEY'];
final String? skip = host == null || keyPath == null
    ? 'ADB_DIRECT_TEST_HOST and ADB_DIRECT_TEST_KEY are not set (see test/device/README.md)'
    : null;

/// The test app (test/fixtures/apks); removed after every test.
const String package = 'app.adbdirect.testapp';

AdbApk apk(String name) => AdbApk.file(File('test/fixtures/apks/$name.apk'));

void main() {
  AdbConnection? connection;
  AdbConnection adb() => connection!;
  var sdk = 0;

  /// Install sessions came with Android 5 (API 21): before, the library says so.
  Future<bool> hasSessions() async {
    if (sdk >= 21) return true;
    await expectLater(adb().packages.installMultiple([apk('app-v2')]), throwsA(isA<AdbNotSupportedException>()));
    markTestSkipped('no install sessions before API 21 (checked: refused)');
    return false;
  }

  Future<String> installedVersion() async =>
      (await adb().shell.run('dumpsys package $package | grep versionCode')).stdoutText;

  setUpAll(() async {
    if (skip != null) return;
    connection = await AdbConnection.connect(host!, port, key: AdbKeyPair.fromPem(File(keyPath!).readAsStringSync()));
    sdk = int.parse((await connection!.shell.run('getprop ro.build.version.sdk')).stdoutText.trim());
  });
  tearDown(() async {
    await connection?.shell.run('pm uninstall $package');
  });
  tearDownAll(() async => connection?.close());

  test('install, reinstall, downgrade refused then allowed', () async {
    final progress = <int>[];
    await adb().packages.install(apk('app-v2'), onProgress: (done, _) => progress.add(done));
    expect(await installedVersion(), contains('versionCode=2'));
    final size = File('test/fixtures/apks/app-v2.apk').lengthSync();
    expect(progress.last, size);
    expect(progress, everyElement(inInclusiveRange(0, size)));
    await adb().packages.install(apk('app-v2'));
    await expectLater(
      adb().packages.install(apk('app-v1')),
      throwsA(
        isA<AdbInstallException>().having((e) => e.failureCode, 'failureCode', 'INSTALL_FAILED_VERSION_DOWNGRADE'),
      ),
    );
    await adb().packages.install(apk('app-v1'), options: const AdbInstallOptions(allowDowngrade: true));
    expect(await installedVersion(), contains('versionCode=1'));
  }, skip: skip);

  test('a base with a split in one session', () async {
    if (!await hasSessions()) return;
    await adb().packages.installMultiple([apk('app-v2'), apk('app-v2-extra')]);
    final paths = (await adb().shell.run('pm path $package')).stdoutText;
    expect(paths, contains('base.apk'));
    expect(paths, contains('split_extra.apk'));
  }, skip: skip);

  test('a split without its base is refused ("Full install must include a base package")', () async {
    if (!await hasSessions()) return;
    // That the session is then abandoned is checked by the unit tests: this device offers the shell user no way to list
    // install sessions.
    await expectLater(
      adb().packages.installMultiple([apk('app-v2-extra')]),
      throwsA(isA<AdbInstallException>().having((e) => e.failureCode, 'failureCode', 'INSTALL_FAILED_INVALID_APK')),
    );
  }, skip: skip);

  test('a file that is not an APK', () async {
    await expectLater(
      adb().packages.install(AdbApk.bytes('junk.apk', List.filled(4096, 7))),
      throwsA(
        isA<AdbInstallException>().having(
          (e) => e.failureCode,
          'failureCode',
          anyOf(startsWith('INSTALL_PARSE_FAILED_'), 'INSTALL_FAILED_INVALID_APK'),
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

  test('list, paths, disable and enable, clear data, permissions', () async {
    await adb().packages.install(apk('app-v2'));
    final listed = await adb().packages.list(system: false);
    final app = listed.firstWhere((p) => p.name == package);
    expect(app.path, endsWith('.apk'));
    if (sdk >= 28) expect(app.versionCode, 2);
    if (sdk >= 26) expect(app.userIds, isNotEmpty);
    expect((await adb().packages.list(system: true)).map((p) => p.name), isNot(contains(package)));
    expect(await adb().packages.paths(package), [app.path]);
    expect(await adb().packages.paths('app.adbdirect.not_installed'), isEmpty);

    await adb().packages.setEnabled(package, enabled: false);
    expect((await adb().packages.list(enabled: false)).map((p) => p.name), contains(package));
    await adb().packages.setEnabled(package, enabled: true);
    expect((await adb().packages.list(enabled: false)).map((p) => p.name), isNot(contains(package)));
    await expectLater(
      adb().packages.setEnabled('app.adbdirect.not_installed', enabled: false),
      throwsA(isA<AdbCommandException>()),
    );

    await adb().packages.clearData(package);
    await expectLater(adb().packages.clearData('app.adbdirect.not_installed'), throwsA(isA<AdbCommandException>()));

    // Granting a permission the app did not ask for passes in silence on some versions (Android 17); an unknown one is
    // refused everywhere runtime permissions exist (Android 6+).
    if (sdk >= 23) {
      for (final change in [adb().packages.grantPermission, adb().packages.revokePermission]) {
        await expectLater(
          change(package, 'android.permission.ADB_DIRECT_NONE'),
          throwsA(isA<AdbCommandException>().having((e) => e.message, 'message', contains('Unknown permission'))),
        );
      }
    }
    if (sdk >= 29) expect(await adb().packages.list(apex: true), isNotEmpty);
  }, skip: skip);

  test(
    'an APEX module that is not one is refused by the package manager',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      if (!adb().supports(AdbFeature.apex)) {
        await expectLater(
          adb().packages.install(AdbApk.bytes('fake.apex', List.filled(4096, 7))),
          throwsA(isA<AdbNotSupportedException>()),
        );
        markTestSkipped('no apex feature (checked: refused before sending)');
        return;
      }
      // Android 14 takes a minute to say "Failure [failed to retrieve SessionInfo]", as with adb.
      await expectLater(
        adb().packages.install(AdbApk.bytes('fake.apex', List.filled(4096, 7))),
        throwsA(isA<AdbInstallException>()),
      );
    },
    skip: skip,
  );

  test('incremental: an app with a split, then a downgrade refused', () async {
    AdbIncrementalApk file(String name) => AdbIncrementalApk.file(File('test/fixtures/apks/$name.apk'));
    if (!adb().supports(AdbFeature.abbExec)) {
      await expectLater(adb().packages.installIncremental([file('app-v2')]), throwsA(isA<AdbNotSupportedException>()));
      markTestSkipped('no abb_exec (checked: refused)');
      return;
    }
    final features = (await adb().shell.run('pm list features')).stdoutText;
    if (!features.contains('android.software.incremental_delivery')) {
      await expectLater(adb().packages.installIncremental([file('app-v2')]), throwsA(isA<AdbInstallException>()));
      markTestSkipped('no incremental delivery on this device (checked: refused)');
      return;
    }
    final install = await adb().packages.installIncremental([file('app-v2'), file('app-v2-extra')]);
    expect(install.output, contains('Success'));
    await install.done.timeout(const Duration(minutes: 1));
    expect(install.isComplete, isTrue);
    expect(await installedVersion(), contains('versionCode=2'));
    final paths = await adb().packages.paths(package);
    expect(paths.map((p) => p.split('/').last), ['base.apk', 'split_extra.apk']);

    await expectLater(
      adb().packages.installIncremental([file('app-v1')]),
      throwsA(
        isA<AdbInstallException>().having((e) => e.failureCode, 'failureCode', 'INSTALL_FAILED_VERSION_DOWNGRADE'),
      ),
    );
  }, skip: skip);
}
