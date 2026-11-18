// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:adb_direct/src/services/properties.dart' show parseGetprop;
import 'package:test/test.dart';

import '../connection/streams_test.dart' show connectTo;
import '../support/shell_device.dart';

void main() {
  group('parseGetprop', () {
    test('a recorded listing, values over several lines included', () {
      final properties = parseGetprop(File('test/fixtures/properties/getprop_tv.txt').readAsStringSync());
      expect(properties['persist.sys.fuse'], 'true');
      expect(properties['persist.sys.boot.reason'], '');
      expect(properties['persist.device_config.runtime_native_boot.iorapd_options'], '');
      expect(
        properties['persist.sys.boot.reason.history'],
        'reboot,shell,1794947900\nreboot,1794938482\nreboot,1794886928\nreboot,1794885289',
      );
      expect(properties['persist.sys.dalvik.vm.lib.2'], 'libart.so');
      expect(properties, hasLength(14));
    });

    test('CR LF line ends from a PTY, brackets inside values, noise', () {
      final properties = parseGetprop('noise\r\n[a]: [x [y] z]\r\n[b]: [one\r\ntwo]\r\n[c]: []\r\n');
      expect(properties, {'a': 'x [y] z', 'b': 'one\ntwo', 'c': ''});
    });
  });

  group('AdbProperties', () {
    test('get, serial with fallback, SDK level asked once', () async {
      final commands = <String>[];
      final (adb, adbd) = await connectTo(
        (session) => serveShellCommands(
          session,
          (command) => switch (command) {
            'getprop ro.serialno' => printed('\n'),
            'getprop ro.boot.serialno' => printed('ABC123\n'),
            'getprop ro.build.version.sdk' => printed('34\n'),
            'getprop \'with space\'' => printed(''),
            _ => printed('', stderr: 'unexpected', exit: 1),
          },
          commands,
        ),
      );
      expect(await adb.properties.serialNumber(), 'ABC123');
      expect(await adb.properties.sdkLevel(), 34);
      expect(await adb.properties.sdkLevel(), 34);
      expect(commands, ['getprop ro.serialno', 'getprop ro.boot.serialno', 'getprop ro.build.version.sdk']);
      expect(() => adb.properties.get('with space'), throwsArgumentError);
      await adb.close();
      await adbd.done();
    });

    test('all() parses the listing; set() quotes and reports refusals', () async {
      final commands = <String>[];
      final (adb, adbd) = await connectTo(
        (session) => serveShellCommands(
          session,
          (command) => switch (command) {
            'getprop' => printed('[a]: [1]\n[b]: [2]\n'),
            "setprop debug.x 'a b'" => printed(''),
            _ => printed('', stderr: 'Failed to set property \'ro.x\' to \'1\'.', exit: 1),
          },
          commands,
        ),
      );
      expect(await adb.properties.all(), {'a': '1', 'b': '2'});
      await adb.properties.set('debug.x', 'a b');
      await expectLater(
        adb.properties.set('ro.x', '1'),
        throwsA(
          isA<AdbCommandException>()
              .having((e) => e.exitCode, 'exitCode', 1)
              .having((e) => e.code, 'code', AdbErrorCode.commandFailed)
              .having((e) => e.message, 'message', contains('Failed to set property')),
        ),
      );
      expect(() => adb.properties.set('debug.x', 'a\nb'), throwsArgumentError);
      await adb.close();
      await adbd.done();
    });
  });
}
