// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// Finds devices: announced on the network (mDNS, as `adb mdns services`), and listening on port 5555 in a range of
// addresses. Probes never show anything on a device.
//
//   dart run example/discover.dart                 # mDNS for ten seconds
//   dart run example/discover.dart 192.168.0       # and a scan of 192.168.0.1-254, port 5555

import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

import 'key.dart';

Future<void> main(List<String> args) async {
  print('mDNS:');
  final browsing = AdbMdnsBrowser().browse(AdbServiceType.all).listen((event) {
    final s = event.service;
    print('  ${event.runtimeType}: ${s.instance} (${s.type}) ${s.address?.address}:${s.port}');
  });
  await Future<void>.delayed(const Duration(seconds: 10));
  await browsing.cancel();

  if (args.isEmpty) return;
  print('scan of ${args.first}.1-254:5555');
  final key = await loadKey();
  await for (final found in AdbProbe.scan([for (var i = 1; i < 255; i++) ('${args.first}.$i', 5555)])) {
    final endpoint = found.endpoint;
    if (endpoint.kind == AdbEndpointKind.notAdb) continue;
    // Whether the device would let this key in without asking (also silent).
    final trusted = endpoint.kind == AdbEndpointKind.adbAuthentication
        ? await AdbProbe.knowsKey(found.host, found.port, key)
        : null;
    print('  ${found.host}: ${endpoint.kind.name}${trusted == null ? '' : ', trusts this key: $trusted'}');
  }
  exit(0);
}
