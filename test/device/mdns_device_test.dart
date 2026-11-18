// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

@Tags(['device'])
library;

import 'dart:async';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';
import 'package:test/test.dart';

/// Browses a service the local Avahi daemon publishes (tool/mdns_publish.py, Linux, python3 with dbus): the real
/// network stack and a real responder. Set ADB_DIRECT_TEST_MDNS=1. It uses its own service type, so no device on the
/// network is involved.
final String? skip = Platform.environment['ADB_DIRECT_TEST_MDNS'] == '1'
    ? null
    : 'set ADB_DIRECT_TEST_MDNS=1 (needs Avahi; see test/device/README.md)';

const type = '_adbdirect-test._tcp';

void main() {
  test('found with serial, port and TXT; lost on the goodbye', () async {
    final instance = 'adb-MDNSTEST${pid % 1000}-Xy12Ab';
    final events = StreamController<AdbServiceEvent>.broadcast();
    final sub = AdbMdnsBrowser().browse([type]).listen(events.add);
    final publisher = await Process.start('python3', ['tool/mdns_publish.py', instance, type, '40123', 'v=1']);
    final watch = Stopwatch()..start();
    final found = await events.stream
        .where((e) => e is AdbServiceFound && e.service.instance == instance)
        .first
        .timeout(const Duration(seconds: 10));
    print('found after ${watch.elapsedMilliseconds} ms: ${found.service}');
    expect(found.service.serial, 'MDNSTEST${pid % 1000}');
    expect(found.service.suffix, 'Xy12Ab');
    expect(found.service.port, 40123);
    expect(found.service.txt, {'v': '1'});
    // The report waits for the announcement's packets from every interface: the first address is a routable one.
    expect(found.service.address!.isLoopback, isFalse);

    watch.reset();
    // A goodbye, not an expiry: legacy answers would live 10 s.
    final lost = events.stream
        .where((e) => e is AdbServiceLost && e.service.instance == instance)
        .first
        .timeout(const Duration(seconds: 4));
    await publisher.stdin.close();
    await lost;
    print('lost after ${watch.elapsedMilliseconds} ms');
    await publisher.exitCode;
    await sub.cancel();
    await events.close();
  }, skip: skip);
}
