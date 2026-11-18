// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../connection/options.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../services/answers.dart' show parseHex4;
import 'server_connection.dart';
import 'smart_socket.dart';

/// A device as the adb server lists it (`adb devices -l`).
@immutable
final class AdbServerDevice {
  /// Creates one.
  const AdbServerDevice({required this.serial, required this.state, this.properties = const {}});

  /// Parses one line of `host:devices-l`: `<serial> <state> product:… model:… device:… transport_id:…`.
  factory AdbServerDevice.parse(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) throw AdbProtocolException('A bad device line: "$line"');
    // "no permissions" spans two words before the properties.
    var state = parts[1];
    var rest = parts.skip(2);
    if (state == 'no' && parts.length > 2 && !parts[2].contains(':')) {
      state = 'no ${parts[2]}';
      rest = parts.skip(3);
    }
    return AdbServerDevice(
      serial: parts[0],
      state: state,
      properties: {
        for (final p in rest)
          if (p.indexOf(':') case final i when i > 0) p.substring(0, i): p.substring(i + 1),
      },
    );
  }

  /// The serial the server knows the device by (`emulator-5554`, `192.168.0.20:5555`, a USB serial).
  final String serial;

  /// `device`, `offline`, `unauthorized`, `authorizing`, `recovery`, `sideload`, `bootloader`, `no permissions`, …
  final String state;

  /// `product`, `model`, `device`, `transport_id`, `usb` where given.
  final Map<String, String> properties;

  /// Whether it is online.
  bool get isOnline => state == 'device';

  /// The model, when the server says.
  String? get model => properties['model'];

  @override
  String toString() => 'AdbServerDevice($serial $state)';
}

/// A client of a running adb server (port 5037): the devices it knows, whether over USB or the network, and connections
/// to them through it.
///
/// Use it on a desktop where `adb` runs anyway (USB devices, for one, are only reachable this way from Dart). [device]
/// gives an [AdbConnection] with the same services as a direct one: shell, files, apps, forwarding.
final class AdbServer {
  /// A client of the server at [host]:[port].
  AdbServer({this.host = '127.0.0.1', this.port = 5037, this.timeout = const Duration(seconds: 10)});

  /// The server's address.
  final Object host;

  /// The server's port.
  final int port;

  /// How long to wait for the server to answer a request.
  final Duration timeout;

  /// How long `connect` and `pair` may take: the server tries the device itself first, for about ten seconds.
  static const Duration _deviceTimeout = Duration(seconds: 45);

  /// The server's protocol version (`adb version` prints it as "Android Debug Bridge version 1.0.n").
  Future<int> version() async {
    final text = await _ask('host:version');
    return parseHex4(text) ?? (throw AdbProtocolException('A bad version answer: "$text"'));
  }

  /// The devices the server knows.
  Future<List<AdbServerDevice>> devices() async => _parseDevices(await _ask('host:devices-l'));

  /// The device list each time it changes, starting with the current one. It stays quiet while nothing changes; cancel
  /// the subscription to stop.
  Stream<List<AdbServerDevice>> trackDevices() async* {
    final socket = await SmartSocket.open(host, port, timeout);
    try {
      await socket.request('host:track-devices-l');
      while (true) {
        yield _parseDevices(await socket.readFrame(timeout: null));
      }
    } on AdbClosedException {
      return;
    } finally {
      socket.destroy();
    }
  }

  /// Asks the server to connect to a device on the network (`adb connect`). Returns the server's message ("connected to
  /// …", "already connected to …"). Throws [AdbUnauthorizedException] when the device refused the server's key,
  /// [AdbUnreachableException] for other failures, with the server's message.
  Future<String> connect(String deviceHost, [int devicePort = 5555]) async {
    final message = await _ask('host:connect:${_target(deviceHost, devicePort)}', timeout: _deviceTimeout);
    final lower = message.toLowerCase();
    if (lower.contains('authenticate')) throw AdbUnauthorizedException(message);
    if (const ['failed', 'unable', 'cannot'].any(lower.startsWith)) throw AdbUnreachableException(message);
    return message;
  }

  /// Asks the server to drop a network device (`adb disconnect`).
  Future<String> disconnect(String deviceHost, [int devicePort = 5555]) =>
      _ask('host:disconnect:${_target(deviceHost, devicePort)}');

  /// Asks the server to pair with a device (`adb pair`), with its own key. Throws [AdbPairingException] with the
  /// server's message when it failed.
  Future<String> pair(String deviceHost, int pairingPort, String code) async {
    final message = await _ask('host:pair:$code:${_target(deviceHost, pairingPort)}', timeout: _deviceTimeout);
    if (message.toLowerCase().contains('failed')) throw AdbPairingException(message);
    return message;
  }

  /// A connection to [serial] through the server. Every stream is a connection to the server asking it to relay one
  /// service; the connection ends when the server stops listing the device as online.
  ///
  /// The server holds the device's authentication, so the connection has no [AdbConnection.acceptedKey]. Reverse
  /// forwarding works to local ports (`AdbReverse.toLocalPort`: the server connects them), not to handlers in code; the
  /// server keeps such forwards until they are removed or the device goes. [options] sets the stall and package manager
  /// timeouts as for a direct connection.
  Future<AdbConnection> device(String serial, {AdbConnectOptions options = const AdbConnectOptions()}) async {
    options.validate();
    final info = (await devices()).where((d) => d.serial == serial).firstOrNull;
    switch (info?.state) {
      case null:
        throw AdbUnreachableException('The adb server knows no "$serial"');
      case 'unauthorized' || 'authorizing':
        throw AdbUnauthorizedException('"$serial" has not accepted the adb server\'s key (${info!.state})');
      case final state when !info!.isOnline:
        throw AdbUnreachableException('"$serial" is $state');
    }

    final features = await _ask('host-serial:$serial:features');
    final banner = AdbBanner(
      systemType: info.state,
      serial: serial,
      properties: {
        'ro.product.name': ?info.properties['product'],
        'ro.product.model': ?info.properties['model'],
        'ro.product.device': ?info.properties['device'],
      },
      features: {
        for (final f in features.split(','))
          if (f.isNotEmpty) AdbFeature(f),
      },
    );
    return ServerConnection(this, serial, banner, options);
  }

  /// One request, one answer (`OKAY` + hex4 + text, or `FAIL` + text).
  Future<String> _ask(String request, {Duration? timeout}) async {
    final wait = timeout ?? this.timeout;
    final socket = await SmartSocket.open(host, port, this.timeout);
    try {
      await socket.request(request, timeout: wait);
      return await socket.readFrame(timeout: wait);
    } finally {
      socket.destroy();
    }
  }

  static String _target(String host, int port) =>
      host.contains(':') && !host.startsWith('[') ? '[$host]:$port' : '$host:$port';

  static List<AdbServerDevice> _parseDevices(String text) => [
    for (final line in const LineSplitter().convert(text))
      if (line.trim().isNotEmpty) AdbServerDevice.parse(line),
  ];
}
