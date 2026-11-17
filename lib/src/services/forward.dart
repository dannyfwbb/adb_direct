// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import '../connection/connection.dart';
import '../errors.dart';
import 'pipe.dart';

/// A local port forwarded to a device service (`adb forward`): each
/// connection to [port] here opens [remote] on the device and copies bytes
/// both ways.
///
/// There is no adb server here, so the forward lives in this process and
/// ends with [close] or with the connection.
final class AdbForward {
  AdbForward._(this._server, this.remote, this._connection)
    : port = _server.port,
      address = _server.address {
    _server.listen(_accept, onError: (Object _) {});
    _connection.done.then((_) => close()).ignore();
  }

  /// Listens on [address]:[port] (0: any free port) and forwards to
  /// [remote] on [connection].
  @internal
  static Future<AdbForward> start(
    AdbConnection connection,
    String remote, {
    required int port,
    required Object address,
  }) async {
    if (connection.isClosed) throw connection.closeReason!;
    final server = await ServerSocket.bind(address, port);
    return AdbForward._(server, remote, connection);
  }

  final ServerSocket _server;
  final AdbConnection _connection;
  final Set<Socket> _clients = {};
  bool _closed = false;

  /// The device service (`tcp:8080`, `localabstract:chrome_devtools_remote`,
  /// `jdwp:1234`, …).
  final String remote;

  /// The local port.
  final int port;

  /// The local address.
  final InternetAddress address;

  /// Connections being forwarded now.
  int get activeConnections => _clients.length;

  /// Whether [close] was called or the connection ended.
  bool get isClosed => _closed;

  /// Stops listening and drops the connections being forwarded.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _server.close();
  }

  Future<void> _accept(Socket client) async {
    if (_closed) {
      client.destroy();
      return;
    }
    _clients.add(client);
    try {
      final stream = await _connection.open(remote);
      if (_closed) {
        await stream.close();
        return;
      }
      await pipe(stream, client);
    } on AdbException {
      // The device refused the service or the connection ended: the local
      // peer sees its connection close.
    } finally {
      _clients.remove(client);
      client.destroy();
    }
  }

  @override
  String toString() => 'AdbForward(${address.address}:$port → $remote)';
}
