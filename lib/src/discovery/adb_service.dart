// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../pairing/pairing_qr.dart' show AdbPairingService;

/// The DNS-SD service types adb devices announce.
abstract final class AdbServiceType {
  /// Classic network debugging (`adb tcpip`, a TV's network debugging switch), usually port 5555.
  static const String connect = '_adb._tcp';

  /// Wireless debugging's connection port (Android 11+, TLS).
  static const String tlsConnect = '_adb-tls-connect._tcp';

  /// Wireless debugging's pairing port, while the pairing screen is open.
  static const String tlsPairing = '_adb-tls-pairing._tcp';

  /// All three.
  static const List<String> all = [connect, tlsConnect, tlsPairing];
}

/// A device's service, as an mDNS browser (or a platform one) found it.
@immutable
final class AdbService {
  /// Creates one.
  AdbService({
    required this.type,
    required this.instance,
    required this.port,
    this.host,
    this.addresses = const [],
    this.txt = const {},
  });

  /// One of [AdbServiceType]'s types (`_adb-tls-connect._tcp`).
  final String type;

  /// The instance name (`adb-14141FDF600081-QXjCrW`, `studio-…`).
  final String instance;

  /// The port to connect (or pair) to.
  final int port;

  /// The device's host name (`Android.local`), when known.
  final String? host;

  /// Its addresses, most useful first (IPv4, routable, loopback last).
  final List<InternetAddress> addresses;

  /// TXT key/value pairs (`v` is the protocol version on TLS services).
  final Map<String, String> txt;

  /// The serial in an `adb-<serial>[-<suffix>]` name, or null.
  String? get serial => parseInstance(instance)?.$1;

  /// The suffix after the serial (random per announcement), or null.
  String? get suffix => parseInstance(instance)?.$2;

  /// Whether this is a QR pairing service (`studio-…`).
  bool get isQrPairing => instance.startsWith('studio-');

  /// The address to use: the first of [addresses].
  InternetAddress? get address => addresses.isEmpty ? null : addresses.first;

  /// Splits `adb-<serial>[-<suffix>]`. Serials may contain `-`; the suffix is the last part when it looks like one (6
  /// letters or digits, as mDNS backends append), else everything is the serial.
  static (String, String?)? parseInstance(String instance) {
    if (!instance.startsWith('adb-') || instance.length == 4) return null;
    final rest = instance.substring(4);
    final dash = rest.lastIndexOf('-');
    if (dash > 0 && RegExp(r'^[A-Za-z0-9]{6}$').hasMatch(rest.substring(dash + 1))) {
      return (rest.substring(0, dash), rest.substring(dash + 1));
    }
    return (rest, null);
  }

  /// Whether every field equals [other]'s.
  bool sameAs(AdbService other) =>
      other.type == type &&
      other.instance == instance &&
      other.port == port &&
      other.host == host &&
      const ListEquality<InternetAddress>().equals(other.addresses, addresses) &&
      const MapEquality<String, String>().equals(other.txt, txt);

  @override
  String toString() => 'AdbService($instance.$type ${address?.address ?? host}:$port)';
}

/// What a browser reports.
sealed class AdbServiceEvent {
  const AdbServiceEvent(this.service);

  /// The service, as it is now (for [AdbServiceLost], as it was last).
  final AdbService service;
}

/// A service appeared (with a port and an address).
final class AdbServiceFound extends AdbServiceEvent {
  /// Creates the event.
  const AdbServiceFound(super.service);

  @override
  String toString() => 'found $service';
}

/// A known service changed: port, addresses or TXT.
final class AdbServiceUpdated extends AdbServiceEvent {
  /// Creates the event.
  const AdbServiceUpdated(super.service);

  @override
  String toString() => 'updated $service';
}

/// A service went away (a goodbye, or its records expired).
final class AdbServiceLost extends AdbServiceEvent {
  /// Creates the event.
  const AdbServiceLost(super.service);

  @override
  String toString() => 'lost $service';
}

/// Anything that finds adb services: `AdbMdnsBrowser` on `dart:io`, or an adapter over a platform browser (iOS
/// `NWBrowser`, Android NSD), which apps need where raw multicast is not allowed.
abstract interface class AdbServiceBrowser {
  /// Services of [types] (from [AdbServiceType]): found, updated, lost, until the subscription is cancelled.
  Stream<AdbServiceEvent> browse(List<String> types);
}

/// Internal helper for implementations.
@internal
String fullType(String type) => type.endsWith('.local') ? type : '$type.local';

/// Pairing services from any browser, for `AdbPairingQr.pair`.
extension AdbServiceBrowserPairing on AdbServiceBrowser {
  /// The `_adb-tls-pairing._tcp` services as they are found (and when they change), as `AdbPairingQr.pair` takes them.
  Stream<AdbPairingService> pairingServices() => browse(const [AdbServiceType.tlsPairing])
      .where((e) => e is! AdbServiceLost && e.service.address != null)
      .map((e) => AdbPairingService(name: e.service.instance, host: e.service.address!, port: e.service.port));
}
