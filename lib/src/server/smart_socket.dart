// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../errors.dart';
import '../protocol/byte_reader.dart';
import '../services/answers.dart' show parseHex4;
import '../transport/tcp_transport.dart';

/// A socket to the adb server, speaking its "smart socket" framing: requests as `<hex4 length><text>`, answers as
/// `OKAY` or `FAIL<hex4 length><message>`.
@internal
final class SmartSocket {
  SmartSocket._(this._socket, this._timeout)
    : _reader = ByteReader(
        _socket,
        onEnd: (error) => error == null
            ? const AdbClosedException('The adb server closed the connection')
            : AdbClosedException('The adb server connection failed', cause: error),
      );

  /// Connects to the server; [timeout] also bounds each answer unless a call gives its own.
  static Future<SmartSocket> open(Object host, int port, Duration timeout) async {
    try {
      // Owned by the SmartSocket, which destroys it.
      // ignore: close_sinks
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      return SmartSocket._(socket, timeout);
    } on SocketException catch (e) {
      throw TcpTransport.mapConnectError(e, 'the adb server at $host:$port');
    }
  }

  final Socket _socket;
  final Duration _timeout;
  final ByteReader _reader;

  /// Sends [request] and reads `OKAY`; a `FAIL` throws with the server's message, mapped by what it says. [transport]
  /// marks the request that picks the device: its refusals are about the device, not a service.
  Future<void> request(String request, {bool transport = false, Duration? timeout}) async {
    final bytes = utf8.encode(request);
    if (bytes.length > 0xffff) {
      throw AdbProtocolException('A request of ${bytes.length} bytes is too long for the adb server');
    }
    _socket
      ..add(ascii.encode(bytes.length.toRadixString(16).padLeft(4, '0')))
      ..add(bytes);

    final wait = timeout ?? _timeout;
    final status = await _text(4, wait);
    if (status == 'OKAY') return;
    if (status != 'FAIL') throw AdbProtocolException('The adb server answered "$status"');

    final message = await readFrame(timeout: wait);
    final lower = message.toLowerCase();
    if (lower.contains('unauthorized') || lower.contains('authorizing')) {
      throw AdbUnauthorizedException('The adb server: $message');
    }
    if (transport || const ['not found', 'offline', 'no devices'].any(lower.contains)) {
      throw AdbUnreachableException('The adb server: $message');
    }
    throw AdbServiceUnavailableException('The adb server refused "$request": $message', service: request);
  }

  /// A `<hex4><text>` frame; [timeout] null waits as long as it takes (tracking, where the server is quiet until
  /// something changes).
  Future<String> readFrame({required Duration? timeout}) async {
    final length = parseHex4(await _text(4, timeout));
    if (length == null) throw const AdbProtocolException('A bad length from the adb server');
    return _text(length, timeout);
  }

  Future<String> _text(int length, Duration? timeout) async => utf8.decode(
    await _reader.take(
      length,
      timeout: timeout,
      onTimeout: () => AdbTimeoutException('The adb server did not answer within $timeout'),
    ),
    allowMalformed: true,
  );

  /// Hands the socket over as a raw stream: what is buffered, whether it ended already, and the subscription for the
  /// rest.
  (Socket, Uint8List, bool, StreamSubscription<List<int>>) detach() {
    final (rest, ended, subscription) = _reader.detach();
    return (_socket, rest, ended, subscription);
  }

  /// Drops the connection.
  void destroy() {
    unawaited(_reader.cancel());
    _socket.destroy();
  }
}
