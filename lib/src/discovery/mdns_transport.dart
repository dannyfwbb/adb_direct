// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// How mDNS packets come and go. Internal: tests replace it.
@internal
abstract interface class MdnsTransport {
  /// Starts receiving; [onPacket] gets every datagram from port 5353 and who sent it; [onError] a failure of the
  /// socket.
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  );

  /// Sends a query to the mDNS group.
  void send(Uint8List packet);

  /// Whether it hears multicast (announcements and goodbyes), or only the unicast answers to its own queries.
  bool get hearsMulticast;

  /// Joins the group on interfaces that came up since the last call.
  Future<void> refreshInterfaces();

  /// Stops.
  Future<void> close();
}

/// mDNS over `dart:io`: port 5353 shared with the system responder when possible, else a port of its own (legacy
/// unicast answers, RFC 6762 6.7).
@internal
final class IoMdnsTransport implements MdnsTransport {
  static final InternetAddress _group = InternetAddress('224.0.0.251');
  RawDatagramSocket? _socket;
  bool _multicast = false;
  final Set<String> _joined = {};

  @override
  bool get hearsMulticast => _multicast;

  @override
  Future<void> start(
    void Function(Uint8List packet, InternetAddress from) onPacket,
    void Function(Object error) onError,
  ) async {
    RawDatagramSocket? shared;
    try {
      shared = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353, reusePort: !Platform.isWindows);
      _socket = shared;
      _multicast = true;
      await refreshInterfaces();
      if (_joined.isEmpty) shared.joinMulticast(_group);
    } on SocketException {
      shared?.close();
      _joined.clear();
      _multicast = false;
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    final socket = _socket!..multicastLoopback = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) break;
        // Responses come from port 5353 (RFC 6762 6).
        if (datagram.port != 5353) continue;
        try {
          onPacket(datagram.data, datagram.address);
        } on Object catch (e) {
          // A packet's problems never end the isolate.
          onError(e);
        }
      }
    }, onError: onError);
  }

  @override
  Future<void> refreshInterfaces() async {
    final socket = _socket;
    if (socket == null || !_multicast) return;
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (_joined.contains(nic.name)) continue;
      try {
        socket.joinMulticast(_group, nic);
        _joined.add(nic.name);
      } on SocketException {
        // An interface without multicast.
      }
    }
  }

  @override
  void send(Uint8List packet) => _socket?.send(packet, _group, 5353);

  @override
  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }
}
