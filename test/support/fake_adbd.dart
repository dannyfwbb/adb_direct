// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/src/errors.dart';
import 'package:adb_direct/src/protocol/message.dart';

import 'fixtures.dart';

/// A script that plays adbd's side of one TCP connection.
typedef FakeAdbdScript = Future<void> Function(FakeAdbdSession session);

/// Decides whether a message the client sent matches the recorded one.
typedef PacketMatcher = bool Function(AdbMessage recorded, AdbMessage actual);

/// Thrown inside a script when the client does something the script did not expect. It fails [FakeAdbd.done].
final class FakeAdbdFailure implements Exception {
  /// Creates the failure.
  FakeAdbdFailure(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'FakeAdbdFailure: $message';
}

/// A scripted adbd on a loopback port.
///
/// Each accepted connection runs the script in a [FakeAdbdSession]. The fake is as strict as the script makes it: an
/// unexpected message from the client fails [done], so tests check what the client sent, not only how it reacts.
final class FakeAdbd {
  FakeAdbd._(this._server, this._script, this._connections) {
    _subscription = _server.listen(_accept);
  }

  /// Starts a fake that serves exactly [connections] connections with [script], then stops listening.
  static Future<FakeAdbd> start(FakeAdbdScript script, {int connections = 1}) async {
    RangeError.checkValueInInterval(connections, 1, 1 << 16, 'connections');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return FakeAdbd._(server, script, connections);
  }

  final ServerSocket _server;
  final FakeAdbdScript _script;
  final int _connections;
  late final StreamSubscription<Socket> _subscription;
  final List<Future<void>> _runs = [];
  final Completer<void> _allAccepted = Completer<void>();
  Object? _firstError;
  StackTrace? _firstStackTrace;

  /// The loopback address to connect to.
  InternetAddress get address => _server.address;

  /// The port to connect to.
  int get port => _server.port;

  /// Completes when the expected connections were served and every script finished.
  ///
  /// Fails with the first script error, or with a [FakeAdbdFailure] when fewer connections than expected arrived within
  /// [timeout].
  Future<void> done({Duration timeout = const Duration(seconds: 10)}) async {
    await _allAccepted.future.timeout(
      timeout,
      onTimeout: () =>
          throw FakeAdbdFailure('expected $_connections connection(s), got ${_runs.length} within $timeout'),
    );
    await Future.wait(_runs);
    if (_firstError case final error?) {
      Error.throwWithStackTrace(error, _firstStackTrace!);
    }
  }

  /// Stops accepting connections.
  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
  }

  void _accept(Socket socket) {
    if (_runs.length == _connections) {
      socket.destroy();
      return;
    }
    final session = FakeAdbdSession._(socket);
    // Errors are captured here, at once, so a failing script never becomes an unhandled error while other connections
    // are still expected.
    final run = Future(() => _script(session))
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            _firstError ??= error;
            _firstStackTrace ??= stackTrace;
          },
        )
        .whenComplete(session._dispose);
    _runs.add(run);
    if (_runs.length == _connections) {
      _allAccepted.complete();
      unawaited(close());
    }
  }
}

/// adbd's side of one connection, driven by a script.
///
/// One script drives a session: concurrent waits on the same session are a test bug and throw [StateError].
final class FakeAdbdSession {
  FakeAdbdSession._(this._socket) {
    // Writes to a client that already went away fail on `done`; the session learns about the close from the read side,
    // so these are expected.
    unawaited(_socket.done.then((_) {}, onError: (Object _) {}));
    _subscription = _socket.listen(
      _onData,
      onError: (Object error) {
        // A client that closes with unread data gets reset: still a close.
        if (error is SocketException && const {104, 54, 10054}.contains(error.osError?.errorCode)) {
          _clientClosed = true;
          _wake();
          return;
        }
        _fail(FakeAdbdFailure('socket error: $error'));
      },
      onDone: () {
        _clientClosed = true;
        _wake();
      },
    );
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _subscription;
  late final AdbMessageReader _reader = AdbMessageReader(onRawMessage: _receivedRaw.add);
  final List<Uint8List> _receivedRaw = [];
  final Queue<AdbMessage> _inbox = Queue<AdbMessage>();
  final List<AdbMessage> _received = [];
  Completer<void>? _waiter;
  Object? _error;
  bool _clientClosed = false;

  /// Whether messages we send carry checksums (protocol version 1.0).
  bool withChecksum = false;

  /// Every message the client sent so far.
  List<AdbMessage> get received => List.unmodifiable(_received);

  /// The exact bytes of every message the client sent, in [received] order (header included, so checksums can be
  /// checked).
  List<Uint8List> get receivedRaw => List.unmodifiable(_receivedRaw);

  /// Sends [message] to the client.
  void send(AdbMessage message) => _socket.add(AdbMessageCodec.encode(message, withChecksum: withChecksum));

  /// Sends raw bytes, for malformed-input tests.
  void sendRaw(List<int> bytes) => _socket.add(bytes);

  /// The next message from the client.
  ///
  /// Fails when the client closes the connection or sends nothing within [timeout].
  Future<AdbMessage> receive({Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      _throwIfFailed();
      if (_inbox.isNotEmpty) return _inbox.removeFirst();
      if (_clientClosed) throw FakeAdbdFailure('client closed the connection while a message was expected');
      if (!await _waitUntil(deadline)) throw FakeAdbdFailure('no message from the client within $timeout');
    }
  }

  /// Receives the next message and checks it against [expected] with [matches] (exact equality by default).
  Future<AdbMessage> expect(AdbMessage expected, {PacketMatcher? matches}) async {
    final actual = await receive();
    if (!(matches ?? _exact)(expected, actual)) {
      throw FakeAdbdFailure('expected $expected, got $actual (payload ${_preview(actual)})');
    }
    return actual;
  }

  /// Fails if the client sends anything within [duration]. The client may close the connection.
  Future<void> expectQuiet(Duration duration) async {
    final deadline = DateTime.now().add(duration);
    while (true) {
      _throwIfFailed();
      if (_inbox.isNotEmpty) {
        throw FakeAdbdFailure(
          'unexpected message from the client: ${_inbox.first} (payload ${_preview(_inbox.first)})',
        );
      }
      if (_clientClosed || !await _waitUntil(deadline)) return;
    }
  }

  /// Waits until the client closes the connection, failing if it sends a message first.
  Future<void> expectClientClose({Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      _throwIfFailed();
      if (_inbox.isNotEmpty) throw FakeAdbdFailure('expected the client to close, got ${_inbox.first}');
      if (_clientClosed) return;
      if (!await _waitUntil(deadline)) throw FakeAdbdFailure('client did not close within $timeout');
    }
  }

  /// Closes the connection from adbd's side after sending what is queued.
  Future<void> close() async {
    await _socket.flush();
    await _socket.close();
  }

  /// Drops the connection at once, without sending what is queued.
  void destroy() => _socket.destroy();

  /// Waits for news (a message, a close, an error) until [deadline]. Returns false when the deadline passed without
  /// news.
  Future<bool> _waitUntil(DateTime deadline) async {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return false;
    if (_waiter != null) throw StateError('Concurrent waits on one FakeAdbdSession');
    final waiter = _waiter = Completer<void>();
    var woke = true;
    await waiter.future.timeout(left, onTimeout: () => woke = false);
    _waiter = null;
    return woke;
  }

  void _throwIfFailed() {
    if (_error case final error?) throw error;
  }

  void _onData(List<int> data) {
    try {
      _reader.add(data);
      for (final message in _reader.drain()) {
        _received.add(message);
        _inbox.add(message);
      }
    } on AdbProtocolException catch (e) {
      _fail(FakeAdbdFailure('client sent a malformed message: $e'));
    }
    _wake();
  }

  void _fail(Object error) {
    _error ??= error;
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Ends the session: sends what is queued, then closes. A client that went away makes the flush fail; then the socket
  /// is just dropped.
  Future<void> _dispose() async {
    const grace = Duration(seconds: 1);
    try {
      // flush() never completes on a socket whose peer is gone: bound it.
      await _socket.flush().timeout(grace);
      await _socket.close().timeout(grace);
    } on Object {
      // The client is gone; nothing left to deliver.
    } finally {
      await _subscription.cancel();
      _socket.destroy();
    }
  }
}

/// A script that replays [fixture]: it sends what the device sent and expects what the recorder sent, in the recorded
/// order. After the last packet it fails if the client sends anything within [quietAfter].
///
/// [matches] compares client messages with recorded ones; the default is [recordedPacketMatcher].
FakeAdbdScript replay(
  Fixture fixture, {
  PacketMatcher? matches,
  Duration quietAfter = const Duration(milliseconds: 100),
}) => (session) async {
  for (final packet in fixture.packets) {
    switch (packet.direction) {
      case FixtureDirection.fromDevice:
        session.send(packet.message);
      case FixtureDirection.toDevice:
        await session.expect(packet.message, matches: matches ?? recordedPacketMatcher);
    }
  }
  await session.expectQuiet(quietAfter);
};

/// Matches a client message to a recorded one exactly, except where the bytes are expected to differ between runs: a
/// token signature (it signs a different random token with a possibly different key).
bool recordedPacketMatcher(AdbMessage recorded, AdbMessage actual) {
  if (recorded.command != actual.command || recorded.arg0 != actual.arg0 || recorded.arg1 != actual.arg1) return false;
  final isSignature = recorded.command == AdbCommand.auth && recorded.arg0 == AdbAuthType.signature.value;
  return isSignature || _exact(recorded, actual);
}

bool _exact(AdbMessage expected, AdbMessage actual) => expected == actual;

String _preview(AdbMessage message) {
  final bytes = message.payload.take(48).toList();
  final printable = bytes.every((b) => b >= 0x20 && b < 0x7f || b == 0);
  return printable
      ? '"${String.fromCharCodes(bytes.where((b) => b != 0))}"'
      : bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
