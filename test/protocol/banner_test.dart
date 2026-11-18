// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:adb_direct/src/protocol/banner.dart';
import 'package:adb_direct/src/protocol/message.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('AdbBanner.parse', () {
    test('the banner of the Google TV emulator (Android 14)', () {
      final cnxn = Fixture.load('handshake/trusted_key').fromDevice.last;
      expect(cnxn.command, AdbCommand.connect);
      // The exact payload captured on 2026-11-17.
      const captured =
          'device::ro.product.name=sdk_google_atv_amati_x86;ro.product.model=AOSP TV on x86;'
          'ro.product.device=emulator_x86_arm;features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,'
          'fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,'
          'sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,'
          'sendrecv_v2_dry_run_send,openscreen_mdns,delayed_ack';
      expect(utf8.decode(cnxn.payload), captured);

      final banner = AdbBanner.parse(cnxn.payload);
      expect(banner.state, AdbDeviceState.device);
      expect(banner.serial, '');
      expect(banner.properties, {
        'ro.product.name': 'sdk_google_atv_amati_x86',
        'ro.product.model': 'AOSP TV on x86',
        'ro.product.device': 'emulator_x86_arm',
      });
      expect(banner.product, 'sdk_google_atv_amati_x86');
      expect(banner.model, 'AOSP TV on x86');
      expect(banner.device, 'emulator_x86_arm');
      expect(banner.features, {
        AdbFeature.shellV2,
        AdbFeature.cmd,
        AdbFeature.statV2,
        AdbFeature.lsV2,
        AdbFeature.fixedPushMkdir,
        AdbFeature.apex,
        AdbFeature.abb,
        AdbFeature.fixedPushSymlinkTimestamp,
        AdbFeature.abbExec,
        AdbFeature.remountShell,
        AdbFeature.trackApp,
        AdbFeature.sendRecvV2,
        AdbFeature.sendRecvV2Brotli,
        AdbFeature.sendRecvV2Lz4,
        AdbFeature.sendRecvV2Zstd,
        AdbFeature.sendRecvV2DryRunSend,
        AdbFeature.openscreenMdns,
        AdbFeature.delayedAck,
      });
      expect(banner.encode(), captured);
    });

    test('a trailing NUL, a trailing semicolon and empty entries', () {
      final banner = AdbBanner.parse(utf8.encode('device::ro.product.model=X;;features=cmd,,shell_v2;\u0000'));
      expect(banner.model, 'X');
      expect(banner.features, {AdbFeature.cmd, AdbFeature.shellV2});
    });

    test('values may contain = and :', () {
      final banner = AdbBanner.parse(utf8.encode('device:abc:ro.product.model=A=B:C;features=cmd'));
      expect(banner.serial, 'abc');
      expect(banner.model, 'A=B:C');
    });

    test('minimal and unusual banners', () {
      expect(AdbBanner.parse(utf8.encode('device')).state, AdbDeviceState.device);
      expect(AdbBanner.parse(utf8.encode('recovery::')).state, AdbDeviceState.recovery);
      final odd = AdbBanner.parse(utf8.encode('fastbootd::'));
      expect(odd.state, AdbDeviceState.unknown);
      expect(odd.systemType, 'fastbootd');
      expect(AdbBanner.parse(utf8.encode('device:serial')).serial, 'serial');
    });

    test('malformed UTF-8 does not throw', () {
      final banner = AdbBanner.parse([0x64, 0x65, 0xff, 0x3a, 0x3a]);
      expect(banner.serial, '');
    });
  });

  group('AdbBanner.host', () {
    test('encodes as adb does, without a trailing NUL', () {
      final banner = AdbBanner.host([AdbFeature.shellV2, AdbFeature.delayedAck]);
      expect(banner.encode(), 'host::features=shell_v2,delayed_ack');
      expect(banner.encode(), isNot(contains('\u0000')));
    });

    test('round-trips through parse', () {
      final banner = AdbBanner.host([AdbFeature.cmd, AdbFeature.statV2]);
      expect(AdbBanner.parse(utf8.encode(banner.encode())), banner);
    });

    test('without features', () {
      expect(AdbBanner.host(const []).encode(), 'host::');
    });
  });

  test('the recorded host banners decode to the features the recorder sent', () {
    final cnxn = Fixture.load('handshake/trusted_key').toDevice.first;
    expect(AdbBanner.parse(cnxn.payload).features, {
      AdbFeature.shellV2,
      AdbFeature.cmd,
      AdbFeature.statV2,
      AdbFeature.lsV2,
    });
  });
}
