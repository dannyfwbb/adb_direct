// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// An AdbServiceBrowser over a platform's own service browser: where raw
// multicast is not allowed (iOS without the multicast entitlement) or not
// wanted (Android NSD), the app browses with the platform and hands the
// results to adb_direct through this interface.
//
// Here the platform side is a stream of maps, as a Flutter EventChannel
// would deliver them from Swift (NWBrowser) or Kotlin (NsdManager):
//
//   {'event': 'found' | 'updated' | 'lost', 'type': '_adb-tls-connect._tcp',
//    'name': 'adb-…', 'host': '192.168.0.20', 'port': 37123,
//    'txt': {'v': '1'}}

import 'dart:async';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

/// Adapts a platform's event stream to [AdbServiceBrowser].
final class PlatformServiceBrowser implements AdbServiceBrowser {
  PlatformServiceBrowser(this._events);

  /// Starts the platform browser for the given types and returns its
  /// events; cancelling the subscription stops it.
  final Stream<Map<Object?, Object?>> Function(List<String> types) _events;

  @override
  Stream<AdbServiceEvent> browse(List<String> types) =>
      _events(types).map(_toEvent).where((e) => e != null).cast();

  static AdbServiceEvent? _toEvent(Map<Object?, Object?> m) {
    final host = m['host'];
    final service = AdbService(
      type: m['type']! as String,
      instance: m['name']! as String,
      port: m['port']! as int,
      addresses: [
        if (host is String && InternetAddress.tryParse(host) != null)
          InternetAddress(host),
      ],
      txt: {
        for (final MapEntry(:key, :value)
            in ((m['txt'] as Map?) ?? const {}).entries)
          '$key': '$value',
      },
    );
    return switch (m['event']) {
      'found' => AdbServiceFound(service),
      'updated' => AdbServiceUpdated(service),
      'lost' => AdbServiceLost(service),
      _ => null,
    };
  }
}

Future<void> main() async {
  // A stand-in for the platform: one TV appears.
  final browser = PlatformServiceBrowser(
    (types) => Stream.value({
      'event': 'found',
      'type': AdbServiceType.tlsConnect,
      'name': 'adb-14141FDF600081-QXjCrW',
      'host': '192.168.0.20',
      'port': 37123,
      'txt': {'v': '1'},
    }),
  );
  await for (final event in browser.browse(AdbServiceType.all)) {
    print('$event, serial ${event.service.serial}');
  }
}
