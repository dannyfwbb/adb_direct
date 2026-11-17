// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import 'pairing.dart';

/// A pairing service found on the network (`_adb-tls-pairing._tcp`).
@immutable
final class AdbPairingService {
  /// Creates one.
  const AdbPairingService({
    required this.name,
    required this.host,
    required this.port,
  });

  /// The mDNS instance name (`studio-…` for a QR code).
  final String name;

  /// An address of the device.
  final Object host;

  /// The pairing port.
  final int port;
}

/// Pairing by QR code, as Android Studio does it: show [text] as a QR code;
/// the device scans it ("Pair device with QR code") and starts a pairing
/// server announced on mDNS under [serviceName]; [pair] waits for that
/// announcement and pairs with [password].
@immutable
final class AdbPairingQr {
  /// A code with a fresh random service name and password.
  factory AdbPairingQr.random() {
    final random = Random.secure();
    String pick(int n) => String.fromCharCodes(
      List.generate(
        n,
        (_) => _alphabet.codeUnitAt(random.nextInt(_alphabet.length)),
      ),
    );
    return AdbPairingQr(serviceName: 'studio-${pick(10)}', password: pick(12));
  }

  /// A code with the given parts: letters, digits and `-` only (the QR
  /// format's `;`, `,`, `:`, `\` and `"` would need escaping that devices
  /// do not all undo).
  AdbPairingQr({required this.serviceName, required this.password}) {
    for (final (name, value) in [
      ('serviceName', serviceName),
      ('password', password),
    ]) {
      if (value.isEmpty || !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value)) {
        throw ArgumentError.value(value, name, 'letters, digits and - only');
      }
    }
  }

  static const String _alphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

  /// The mDNS instance name the device will announce.
  final String serviceName;

  /// The pairing password (what a code would be).
  final String password;

  /// What the QR code encodes.
  String get text => 'WIFI:T:ADB;S:$serviceName;P:$password;;';

  /// Waits on [services] (announcements of `_adb-tls-pairing._tcp`, from
  /// any mDNS browser) for the one named [serviceName], then pairs [key]
  /// with it; see [AdbPairing.pair]. Throws [AdbTimeoutException] when the
  /// device does not appear within [waitTimeout] (the code was not
  /// scanned), [AdbCancelledException] when [cancelOn] completes first.
  Future<AdbPairedDevice> pair({
    required Stream<AdbPairingService> services,
    required AdbKeyPair key,
    Duration waitTimeout = const Duration(minutes: 2),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration timeout = const Duration(seconds: 30),
    Future<void>? cancelOn,
    void Function(String line)? keyLog,
    AdbClock clock = AdbClock.system,
  }) async {
    final found = Completer<AdbPairingService>();
    final subscription = services.listen(
      (service) {
        if (service.name == serviceName && !found.isCompleted) {
          found.complete(service);
        }
      },
      onError: (Object e) {
        if (!found.isCompleted) {
          found.completeError(
            AdbUnreachableException('The service browser failed', cause: e),
          );
        }
      },
    );
    final timer = clock.timer(waitTimeout, () {
      if (!found.isCompleted) {
        found.completeError(
          AdbTimeoutException(
            'No device announced $serviceName within $waitTimeout',
          ),
        );
      }
    });
    void cancel() {
      if (!found.isCompleted) {
        found.completeError(
          const AdbCancelledException('QR pairing was cancelled'),
        );
      }
    }

    cancelOn?.then((_) => cancel(), onError: (Object _) => cancel()).ignore();
    final AdbPairingService service;
    try {
      service = await found.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
    return AdbPairing.pair(
      service.host,
      service.port,
      code: password,
      key: key,
      connectTimeout: connectTimeout,
      timeout: timeout,
      cancelOn: cancelOn,
      keyLog: keyLog,
      clock: clock,
    );
  }
}
