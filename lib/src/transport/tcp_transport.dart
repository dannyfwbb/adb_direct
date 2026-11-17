// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import 'transport.dart';

/// TCP to adbd, on a [RawSocket].
///
/// `RawSocket` rather than `Socket` because a live connection must be able
/// to switch to TLS mid-stream after `STLS`, which `dart:io` supports only
/// through `RawSecureSocket.secure(raw, subscription:)`.
final class TcpTransport implements AdbTransport {
  TcpTransport._(this._socket);

  /// Opens a TCP connection to [host]:[port] within [timeout].
  ///
  /// Throws [AdbRefusedException] when the device actively refused (nothing
  /// listens on the port), [AdbUnreachableException] for everything else:
  /// no route, no network, or no answer in time.
  ///
  /// When [cancelOn] completes first, the attempt stops and the call throws
  /// [AdbCancelledException].
  static Future<TcpTransport> connect(
    Object host,
    int port, {
    required Duration timeout,
    Future<void>? cancelOn,
  }) async {
    var cancelled = false;
    ConnectionTask<RawSocket>? task;
    void cancel() {
      cancelled = true;
      task?.cancel();
    }

    cancelOn?.then((_) => cancel(), onError: (Object _) => cancel()).ignore();
    try {
      task = await RawSocket.startConnect(host, port);
      if (cancelled) task.cancel();
      final socket = await task.socket.timeout(
        timeout,
        onTimeout: () {
          task?.cancel();
          throw const SocketException('Connection timed out');
        },
      );
      if (cancelled) {
        socket.close().ignore();
        throw _cancelled;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      return TcpTransport._(socket);
    } on SocketException catch (e) {
      if (cancelled) throw _cancelled;
      throw mapConnectError(e, '$host:$port');
    }
  }

  static const _cancelled = AdbCancelledException(
    'The connection attempt was cancelled',
  );

  /// The [AdbException] for a failed connect to [target].
  static AdbException mapConnectError(SocketException e, String target) {
    final code = e.osError?.errorCode;
    if (code != null && _refusedCodes.contains(code)) {
      return AdbRefusedException('$target refused the connection', cause: e);
    }
    return AdbUnreachableException('Could not reach $target', cause: e);
  }

  // ECONNREFUSED on Linux and Android, macOS and iOS, Windows.
  static const Set<int> _refusedCodes = {111, 61, 10061};

  RawSocket _socket;
  final Queue<Uint8List> _pending = Queue<Uint8List>();
  int _pendingOffset = 0;
  int _pendingBytes = 0;
  AdbTransportListener? _listener;
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<void>? _drained;
  bool _ended = false;

  @override
  int get pendingWriteBytes => _pendingBytes;

  @override
  void start(AdbTransportListener listener) {
    if (_listener != null) throw StateError('Transport already started');
    _listener = listener;
    _subscription = _socket.listen(_onEvent, onError: _fail, onDone: _onDone);
  }

  @override
  void write(Uint8List bytes) {
    if (_ended || bytes.isEmpty) return;
    _pending.add(bytes);
    _pendingBytes += bytes.length;
    _flush();
  }

  @override
  Future<void> close({required Duration drainTimeout}) async {
    if (_ended) return;
    if (_pendingBytes > 0) {
      final drained = (_drained ??= Completer<void>()).future;
      var timedOut = false;
      await drained.timeout(drainTimeout, onTimeout: () => timedOut = true);
      if (timedOut) {
        destroy();
        return;
      }
    }
    _end();
    await _socket.close();
  }

  @override
  void destroy() {
    if (_ended) return;
    _end();
    unawaited(_socket.close());
  }

  @override
  Future<X509Certificate?> startTls({
    required SecurityContext context,
    void Function(String line)? keyLog,
  }) async {
    if (_ended) throw const AdbClosedException('The connection is closed');
    if (_pendingBytes > 0) {
      // STLS must leave before the ClientHello.
      await (_drained ??= Completer<void>()).future;
      if (_ended) throw const AdbClosedException('The connection is closed');
    }
    // The subscription must stay active: RawSecureSocket takes it over and
    // refuses a paused one. adbd sends nothing between STLS and our
    // ClientHello, so no plain bytes are lost here.
    final upgrade = _upgrade = Completer<X509Certificate?>();
    // Its outcome is delivered through [upgrade].
    // ignore: discarded_futures
    RawSecureSocket.secure(
          _socket,
          subscription: _subscription,
          context: context,
          onBadCertificate: (_) => true,
          keyLog: keyLog,
        )
        .then(
          (secure) {
            if (upgrade.isCompleted) {
              // Closed meanwhile.
              unawaited(secure.close());
              return;
            }
            _upgrade = null;
            _socket = secure;
            _subscription = secure.listen(
              _onEvent,
              onError: _fail,
              onDone: _onDone,
            );
            upgrade.complete(secure.peerCertificate);
          },
          onError: (Object e) {
            if (upgrade.isCompleted) return;
            _upgrade = null;
            destroy();
            upgrade.completeError(
              AdbProtocolException('The TLS handshake failed: $e', cause: e),
            );
          },
        )
        .ignore();
    return upgrade.future;
  }

  /// A TLS upgrade in progress; a close or destroy fails it at once (the
  /// TLS layer owns the subscription then and would wait forever).
  Completer<X509Certificate?>? _upgrade;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        // Read only what is available: a read() with nothing available
        // throws "Read failed" on Linux (Dart 3.13) instead of returning
        // null.
        while (!_ended && _socket.available() > 0) {
          final data = _socket.read();
          if (data == null) break;
          _listener!.onData(data);
        }
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        _onDone();
    }
  }

  void _flush() {
    try {
      while (_pending.isNotEmpty) {
        final chunk = _pending.first;
        final written = _socket.write(chunk, _pendingOffset);
        _pendingOffset += written;
        _pendingBytes -= written;
        if (_pendingOffset < chunk.length) {
          _socket.writeEventsEnabled = true;
          return;
        }
        _pending.removeFirst();
        _pendingOffset = 0;
      }
    } on SocketException catch (e) {
      _fail(e);
      return;
    }
    final drained = _drained;
    _drained = null;
    drained?.complete();
  }

  void _onDone() {
    if (_ended) return;
    final listener = _listener;
    _end();
    listener?.onClosed();
  }

  void _fail(Object error) {
    if (_ended) return;
    final listener = _listener;
    _end();
    unawaited(_socket.close());
    listener?.onError(
      AdbClosedException('The connection failed: $error', cause: error),
    );
  }

  void _end() {
    _ended = true;
    final upgrade = _upgrade;
    _upgrade = null;
    if (upgrade != null && !upgrade.isCompleted) {
      upgrade.completeError(
        const AdbClosedException(
          'The connection closed during the TLS handshake',
        ),
      );
    }
    _pending.clear();
    _pendingBytes = 0;
    _pendingOffset = 0;
    unawaited(_subscription?.cancel());
    final drained = _drained;
    _drained = null;
    drained?.complete();
  }
}
