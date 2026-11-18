// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// A capability named in a `CNXN` banner.
///
/// A feature is used only when both sides list it. Names the library does not know are kept as they are, so
/// [AdbBanner.features] always holds what the device said.
extension type const AdbFeature(String name) implements Object {
  /// Shell protocol v2: separate stdout and stderr, and the exit code.
  static const shellV2 = AdbFeature('shell_v2');

  /// The `cmd` binary exists (`cmd package install` streams APKs).
  static const cmd = AdbFeature('cmd');

  /// Sync `STA2` and `LST2` (64-bit sizes, errno).
  static const statV2 = AdbFeature('stat_v2');

  /// Sync `LIS2` with `DNT2` entries.
  static const lsV2 = AdbFeature('ls_v2');

  /// Push creates parent directories correctly.
  static const fixedPushMkdir = AdbFeature('fixed_push_mkdir');

  /// `install --apex`.
  static const apex = AdbFeature('apex');

  /// The `abb:` Binder bridge service.
  static const abb = AdbFeature('abb');

  /// Push keeps symlink timestamps.
  static const fixedPushSymlinkTimestamp = AdbFeature('fixed_push_symlink_timestamp');

  /// The `abb_exec:` Binder bridge service without shell protocol.
  static const abbExec = AdbFeature('abb_exec');

  /// `remount` runs as a shell command and reports its output.
  static const remountShell = AdbFeature('remount_shell');

  /// The `track-app` service.
  static const trackApp = AdbFeature('track_app');

  /// Sync `SND2` and `RCV2`.
  static const sendRecvV2 = AdbFeature('sendrecv_v2');

  /// Brotli compression in sync v2.
  static const sendRecvV2Brotli = AdbFeature('sendrecv_v2_brotli');

  /// LZ4 compression in sync v2.
  static const sendRecvV2Lz4 = AdbFeature('sendrecv_v2_lz4');

  /// Zstandard compression in sync v2.
  static const sendRecvV2Zstd = AdbFeature('sendrecv_v2_zstd');

  /// Dry-run `SND2`.
  static const sendRecvV2DryRunSend = AdbFeature('sendrecv_v2_dry_run_send');

  /// Delayed acknowledgements: several writes in flight per stream.
  static const delayedAck = AdbFeature('delayed_ack');

  /// The `dev-raw:` service.
  static const devRaw = AdbFeature('devraw');

  // Features that concern the adb host and server rather than a device connection. adbd shares the feature table, so
  // devices may list some of them (the Android 14 TV emulator sends `openscreen_mdns`).

  /// The adb server uses libusb.
  static const libusb = AdbFeature('libusb');

  /// The adb server can push with `sync` semantics.
  static const pushSync = AdbFeature('push_sync');

  /// The adb server discovers with Openscreen mDNS.
  static const openscreenMdns = AdbFeature('openscreen_mdns');

  /// The adb server's device tracker speaks protobuf.
  static const deviceTrackerProtoFormat = AdbFeature('devicetracker_proto_format');

  /// `track-app` includes package names.
  static const appInfo = AdbFeature('app_info');

  /// The adb server reports its status.
  static const serverStatus = AdbFeature('server_status');

  /// The adb server streams mDNS services.
  static const trackMdns = AdbFeature('track_mdns');
}

/// The state a device reports in its banner.
enum AdbDeviceState {
  /// Booted Android.
  device,

  /// The bootloader.
  bootloader,

  /// Recovery.
  recovery,

  /// Recovery, waiting for `adb sideload`.
  sideload,

  /// Rescue mode.
  rescue,

  /// A host (the other end of a connection we accepted).
  host,

  /// A state this library does not know; see [AdbBanner.systemType].
  unknown;

  /// The state for a banner's system type.
  static AdbDeviceState fromSystemType(String systemType) =>
      systemType == unknown.name ? unknown : values.asNameMap()[systemType] ?? unknown;
}

/// The identity string carried in a `CNXN` message: `<systemtype>:<serial>:<key>=<value>;…;features=<a>,<b>,…`.
@immutable
final class AdbBanner {
  /// Creates a banner.
  AdbBanner({
    required this.systemType,
    this.serial = '',
    Map<String, String> properties = const {},
    Set<AdbFeature> features = const {},
  }) : properties = Map.unmodifiable(properties),
       features = Set.unmodifiable(features);

  /// Parses the payload of a `CNXN` message.
  ///
  /// Tolerates trailing NULs and semicolons, empty entries and entries without a value. Values may contain `=` and `:`.
  factory AdbBanner.parse(List<int> payload) {
    var text = utf8.decode(payload, allowMalformed: true);
    final end = text.indexOf('\u0000');
    if (end >= 0) text = text.substring(0, end);

    final firstColon = text.indexOf(':');
    if (firstColon < 0) return AdbBanner(systemType: text);
    final secondColon = text.indexOf(':', firstColon + 1);
    final systemType = text.substring(0, firstColon);
    final serial = secondColon < 0 ? text.substring(firstColon + 1) : text.substring(firstColon + 1, secondColon);
    final rest = secondColon < 0 ? '' : text.substring(secondColon + 1);

    final properties = <String, String>{};
    for (final entry in rest.split(';')) {
      final equals = entry.indexOf('=');
      if (equals <= 0) continue;
      properties[entry.substring(0, equals)] = entry.substring(equals + 1);
    }
    final featureList = properties.remove(_featuresKey) ?? '';
    final features = {
      for (final name in featureList.split(','))
        if (name.isNotEmpty) AdbFeature(name),
    };
    return AdbBanner(systemType: systemType, serial: serial, properties: properties, features: features);
  }

  /// The banner a host sends: `host::features=<a>,<b>,…`, with no trailing NUL (adbd would keep a NUL as part of the
  /// last feature's name).
  factory AdbBanner.host(Iterable<AdbFeature> features) => AdbBanner(systemType: 'host', features: features.toSet());

  static const String _featuresKey = 'features';

  /// The first field: `device`, `recovery`, `host`, …
  final String systemType;

  /// The second field; empty in banners from adbd over the network.
  final String serial;

  /// Every `key=value` entry except `features`.
  final Map<String, String> properties;

  /// The features listed.
  final Set<AdbFeature> features;

  /// [systemType] as a known state.
  AdbDeviceState get state => AdbDeviceState.fromSystemType(systemType);

  /// `ro.product.name`, if sent.
  String? get product => properties['ro.product.name'];

  /// `ro.product.model`, if sent.
  String? get model => properties['ro.product.model'];

  /// `ro.product.device`, if sent.
  String? get device => properties['ro.product.device'];

  /// Whether [feature] is listed.
  bool supports(AdbFeature feature) => features.contains(feature);

  /// The banner as text, in the order adb writes it.
  String encode() {
    final entries = [
      for (final MapEntry(:key, :value) in properties.entries) '$key=$value',
      if (features.isNotEmpty) '$_featuresKey=${features.map((f) => f.name).join(',')}',
    ];
    return '$systemType:$serial:${entries.join(';')}';
  }

  @override
  bool operator ==(Object other) =>
      other is AdbBanner &&
      other.systemType == systemType &&
      other.serial == serial &&
      const MapEquality<String, String>().equals(other.properties, properties) &&
      const SetEquality<AdbFeature>().equals(other.features, features);

  @override
  int get hashCode => Object.hash(
    systemType,
    serial,
    Object.hashAllUnordered(properties.entries.map((e) => (e.key, e.value))),
    Object.hashAllUnordered(features),
  );

  @override
  String toString() => 'AdbBanner(${encode()})';
}
