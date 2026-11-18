// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../connection/connection.dart';
import '../connection/options.dart';
import '../crypto/adb_key_pair.dart';
import '../errors.dart';
import '../protocol/banner.dart';
import '../protocol/byte_queue.dart';
import '../services/answers.dart' show parseHex4;
import '../stream/adb_stream.dart';
import '../transport/tcp_transport.dart';

/// A device as the adb server lists it (`adb devices -l`).
@immutable
final class AdbServerDevice {
  /// Creates one.
  const AdbServerDevice({required this.serial, required this.state, this.properties = const {}});

  /// Parses one line of `host:devices-l`:
  /// `<serial> <state> product:… model:… device:… transport_id:…`.
  factory AdbServerDevice.parse(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw AdbProtocolException('A bad device line: "$line"');
    }
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

  /// The serial the server knows the device by (`emulator-5554`,
  /// `192.168.0.20:5555`, a USB serial).
  final String serial;

  /// `device`, `offline`, `unauthorized`, `authorizing`, `recovery`,
  /// `sideload`, `bootloader`, `no permissions`, …
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

/// A client of a running adb server (port 5037): the devices it knows,
/// whether over USB or the network, and connections to them through it.
///
/// Use it on a desktop where `adb` runs anyway (USB devices, for one,
/// are only reachable this way from Dart). [device] gives an
/// [AdbConnection] with the same services as a direct one: shell, files,
/// apps, forwarding.
final class AdbServer {
  /// A client of the server at [host]:[port].
  AdbServer({this.host = '127.0.0.1', this.port = 5037, this.timeout = const Duration(seconds: 10)});

  /// The server's address.
  final Object host;

  /// The server's port.
  final int port;

  /// How long to wait for the server to answer a request.
  final Duration timeout;

  /// How long `connect` and `pair` may take: the server tries the device
  /// itself first, for about ten seconds.
  static const Duration _deviceTimeout = Duration(seconds: 45);

  /// The server's protocol version (`adb version` prints it as
  /// "Android Debug Bridge version 1.0.n").
  Future<int> version() async {
    final text = await _ask('host:version');
    final value = parseHex4(text);
    if (value == null) {
      throw AdbProtocolException('A bad version answer: "$text"');
    }
    return value;
  }

  /// The devices the server knows.
  Future<List<AdbServerDevice>> devices() async => _parseDevices(await _ask('host:devices-l'));

  /// The device list each time it changes, starting with the current one.
  /// It stays quiet while nothing changes; cancel the subscription to stop.
  Stream<List<AdbServerDevice>> trackDevices() async* {
    final socket = await _SmartSocket.open(host, port, timeout);
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

  /// Asks the server to connect to a device on the network (`adb connect`).
  /// Returns the server's message ("connected to …", "already connected
  /// to …"). Throws [AdbUnauthorizedException] when the device refused the
  /// server's key, [AdbUnreachableException] for other failures, with the
  /// server's message.
  Future<String> connect(String deviceHost, [int devicePort = 5555]) async {
    final message = await _ask('host:connect:${_target(deviceHost, devicePort)}', timeout: _deviceTimeout);
    final lower = message.toLowerCase();
    if (lower.contains('authenticate')) {
      throw AdbUnauthorizedException(message);
    }
    if (lower.startsWith('failed') || lower.startsWith('unable') || lower.startsWith('cannot')) {
      throw AdbUnreachableException(message);
    }
    return message;
  }

  /// Asks the server to drop a network device (`adb disconnect`).
  Future<String> disconnect(String deviceHost, [int devicePort = 5555]) =>
      _ask('host:disconnect:${_target(deviceHost, devicePort)}');

  /// Asks the server to pair with a device (`adb pair`), with its own key.
  /// Throws [AdbPairingException] with the server's message when it failed.
  Future<String> pair(String deviceHost, int pairingPort, String code) async {
    final message = await _ask('host:pair:$code:${_target(deviceHost, pairingPort)}', timeout: _deviceTimeout);
    if (message.toLowerCase().contains('failed')) {
      throw AdbPairingException(message);
    }
    return message;
  }

  /// A connection to [serial] through the server. Every stream is a
  /// connection to the server asking it to relay one service; the
  /// connection ends when the server stops listing the device as online.
  ///
  /// The server holds the device's authentication, so the connection has
  /// no [AdbConnection.acceptedKey]. Reverse forwarding works to local
  /// ports (`AdbReverse.toLocalPort`: the server connects them), not to
  /// handlers in code; the server keeps such forwards until they are
  /// removed or the device goes. [options] sets the stall and package
  /// manager timeouts as for a direct connection.
  Future<AdbConnection> device(String serial, {AdbConnectOptions options = const AdbConnectOptions()}) async {
    options.validate();
    final listed = (await devices()).where((d) => d.serial == serial);
    if (listed.isEmpty) {
      throw AdbUnreachableException('The adb server knows no "$serial"');
    }
    final info = listed.first;
    if (info.state == 'unauthorized' || info.state == 'authorizing') {
      throw AdbUnauthorizedException('"$serial" has not accepted the adb server\'s key (${info.state})');
    }
    if (!info.isOnline) {
      throw AdbUnreachableException('"$serial" is ${info.state}');
    }
    final features = (await _ask(
      'host-serial:$serial:features',
    )).split(',').where((f) => f.isNotEmpty).map(AdbFeature.new).toSet();
    final connection = ServerConnection(
      this,
      serial,
      AdbBanner(
        systemType: info.state,
        serial: serial,
        properties: {
          'ro.product.name': ?info.properties['product'],
          'ro.product.model': ?info.properties['model'],
          'ro.product.device': ?info.properties['device'],
        },
        features: features,
      ),
      options,
    ).._watch();
    return connection;
  }

  /// One request, one answer (`OKAY` + hex4 + text, or `FAIL` + text).
  Future<String> _ask(String request, {Duration? timeout}) async {
    final wait = timeout ?? this.timeout;
    final socket = await _SmartSocket.open(host, port, this.timeout);
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

/// adb's "smart socket" framing to the server.
final class _SmartSocket {
  _SmartSocket._(this._socket, this._timeout) {
    _subscription = _socket.listen(
      (data) {
        _buffer.add(data);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  static Future<_SmartSocket> open(Object host, int port, Duration timeout) async {
    try {
      // Owned by the _SmartSocket, which destroys it.
      // ignore: close_sinks
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      return _SmartSocket._(socket, timeout);
    } on SocketException catch (e) {
      throw TcpTransport.mapConnectError(e, 'the adb server at $host:$port');
    }
  }

  final Socket _socket;
  final Duration _timeout;
  late final StreamSubscription<Uint8List> _subscription;
  final ByteQueue _buffer = ByteQueue();
  Completer<void>? _waiting;
  Object? _error;
  bool _closed = false;

  /// Sends [request] and reads `OKAY`; a `FAIL` throws with the server's
  /// message, mapped by what it says. [transport] marks the request that
  /// picks the device: its refusals are about the device, not a service.
  Future<void> request(String request, {bool transport = false, Duration? timeout}) async {
    final bytes = utf8.encode(request);
    if (bytes.length > 0xffff) {
      throw AdbProtocolException('A request of ${bytes.length} bytes is too long for the adb server');
    }
    _socket
      ..add(ascii.encode(bytes.length.toRadixString(16).padLeft(4, '0')))
      ..add(bytes);
    final wait = timeout ?? _timeout;
    final status = ascii.decode(await _take(4, timeout: wait), allowInvalid: true);
    if (status == 'OKAY') return;
    if (status != 'FAIL') {
      throw AdbProtocolException('The adb server answered "$status"');
    }
    final message = await readFrame(timeout: wait);
    final lower = message.toLowerCase();
    if (lower.contains('unauthorized') || lower.contains('authorizing')) {
      throw AdbUnauthorizedException('The adb server: $message');
    }
    if (transport || lower.contains('not found') || lower.contains('offline') || lower.contains('no devices')) {
      throw AdbUnreachableException('The adb server: $message');
    }
    throw AdbServiceUnavailableException('The adb server refused "$request": $message', service: request);
  }

  /// A `<hex4><text>` frame; [timeout] null waits as long as it takes
  /// (tracking, where the server is quiet until something changes).
  Future<String> readFrame({required Duration? timeout}) async {
    final length = parseHex4(ascii.decode(await _take(4, timeout: timeout), allowInvalid: true));
    if (length == null) {
      throw const AdbProtocolException('A bad length from the adb server');
    }
    return utf8.decode(await _take(length, timeout: timeout), allowMalformed: true);
  }

  Future<Uint8List> _take(int count, {required Duration? timeout}) async {
    while (_buffer.length < count) {
      _throwIfEnded();
      final waiting = _waiting = Completer<void>();
      if (timeout == null) {
        await waiting.future;
      } else {
        await waiting.future.timeout(
          timeout,
          onTimeout: () => throw AdbTimeoutException('The adb server did not answer within $timeout'),
        );
      }
    }
    return _buffer.take(count);
  }

  void _throwIfEnded() {
    if (_error case final e?) {
      throw AdbClosedException('The adb server connection failed', cause: e);
    }
    if (_closed) {
      throw const AdbClosedException('The adb server closed the connection');
    }
  }

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// Hands the socket over as a raw stream: what is buffered, whether it
  /// ended already, and the subscription for the rest.
  (Socket, Uint8List, bool, StreamSubscription<Uint8List>) detach() =>
      (_socket, _buffer.take(_buffer.length), _closed || _error != null, _subscription);

  void destroy() {
    unawaited(_subscription.cancel());
    _socket.destroy();
  }
}

/// A connection to one device through the adb server.
///
/// Created by [AdbServer.device]; not meant to be extended.
@internal
final class ServerConnection extends AdbConnection {
  /// Creates it.
  ServerConnection(this._server, this.serial, this._banner, this._options) : super.base();

  final AdbServer _server;
  final AdbBanner _banner;
  final AdbConnectOptions _options;

  /// The device's serial at the server.
  final String serial;

  final Set<_SocketStreamCore> _streams = {};
  final Completer<void> _done = Completer<void>();
  AdbException? _closeReason;
  StreamSubscription<List<AdbServerDevice>>? _tracking;

  /// Ends the connection when the server stops listing the device online
  /// (or the server goes away).
  void _watch() {
    _tracking = _server.trackDevices().listen(
      (devices) {
        final now = devices.where((d) => d.serial == serial);
        if (now.isEmpty || !now.first.isOnline) {
          _fail(AdbClosedException(now.isEmpty ? '"$serial" left the adb server' : '"$serial" is ${now.first.state}'));
        }
      },
      onError: (Object e) => _fail(AdbClosedException('Lost the adb server', cause: e)),
      onDone: () => _fail(const AdbClosedException('Lost the adb server')),
    );
  }

  void _fail(AdbException reason) {
    if (_closeReason != null) return;
    _closeReason = reason;
    unawaited(_tracking?.cancel());
    for (final s in _streams.toList()) {
      s.fail(reason);
    }
    _done.complete();
  }

  @override
  AdbClock get clock => AdbClock.system;

  @override
  AdbBanner get device => _banner;

  @override
  AdbKeyPair? get acceptedKey => null;

  @override
  int get protocolVersion => 0x01000001;

  @override
  bool get isTls => false;

  @override
  Uint8List? get deviceCertificate => null;

  /// The longest service name the server's framing carries.
  @override
  int get maxPayload => 0xffff;

  @override
  bool get delayedAck => false;

  @override
  bool get isClosed => _closeReason != null;

  @override
  AdbException? get closeReason => _closeReason;

  @override
  Future<void> get done => _done.future;

  @override
  AdbConnectOptions get options => _options;

  @override
  AdbStream openStream(String service) {
    if (_closeReason case final reason?) throw reason;
    final core = _SocketStreamCore(service);
    _streams.add(core);
    core.done.then((_) => _streams.remove(core)).ignore();
    unawaited(core.start(_server, serial));
    return AdbStream(core);
  }

  @override
  Future<void> close({bool drain = true}) async {
    if (_closeReason != null) return;
    final streams = _streams.toList();
    _fail(const AdbCancelledException('The connection was closed by the caller'));
    for (final s in streams) {
      await s.done;
    }
  }

  /// The server connects reverse forwards to local ports itself
  /// (`tcp:<port>` targets on this machine); handlers in code need the ADB
  /// protocol here.
  @override
  void registerReverseTarget(String label, FutureOr<void> Function(AdbStream) handler) {
    if (!RegExp(r'^tcp:\d+$').hasMatch(label)) {
      throw const AdbNotSupportedException(
        'Through an adb server, reverse forwarding reaches local ports on '
        'this machine only (toLocalPort with the default host)',
      );
    }
  }

  @override
  void unregisterReverseTarget(String label) {}
}

/// A stream relayed by the server: a socket that asked for
/// `host:transport:<serial>`, then for the service.
final class _SocketStreamCore implements StreamCore {
  _SocketStreamCore(this.service) {
    _input = StreamController<Uint8List>(onCancel: close);
  }

  @override
  final String service;

  final Completer<void> _opened = Completer<void>();
  final Completer<void> _done = Completer<void>();
  late final StreamController<Uint8List> _input;
  final StreamController<int> _acks = StreamController<int>.broadcast();
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  AdbException? _closeReason;
  bool _closed = false;
  int _written = 0;
  int _flushed = 0;
  Future<void> _writes = Future.value();

  Future<void> start(AdbServer server, String serial) async {
    _opened.future.ignore();
    _SmartSocket? smart;
    try {
      smart = await _SmartSocket.open(server.host, server.port, server.timeout);
      await smart.request('host:transport:$serial', transport: true);
      await smart.request(service);
      if (_closed) {
        smart.destroy();
        return;
      }
      final (socket, rest, ended, subscription) = smart.detach();
      _socket = socket;
      _subscription = subscription;
      if (rest.isNotEmpty) _input.add(rest);
      if (ended) {
        _opened.complete();
        _finish(null);
        return;
      }
      subscription
        ..onData((data) {
          if (!_input.isClosed) _input.add(data);
        })
        ..onError((Object e) => _finish(AdbClosedException('The relayed stream failed', cause: e)))
        ..onDone(() => _finish(null));
      _input
        ..onPause = subscription.pause
        ..onResume = subscription.resume;
      _opened.complete();
    } on AdbServiceUnavailableException catch (e) {
      smart?.destroy();
      _finish(AdbServiceUnavailableException('The device refused to open "$service": ${e.message}', service: service));
    } on AdbException catch (e) {
      smart?.destroy();
      _finish(e);
    } on Object catch (e) {
      smart?.destroy();
      _finish(AdbProtocolException('Opening "$service" failed: $e', cause: e));
    }
  }

  /// The connection ended under this stream.
  void fail(AdbException reason) => _finish(reason);

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> get opened => _opened.future;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  AdbException? get closeReason => _closeReason;

  /// What the server's socket has taken: the device's own
  /// acknowledgements stay between the server and the device.
  @override
  int get acknowledgedBytes => _flushed;

  @override
  Stream<int> get acknowledgements => _acks.stream;

  @override
  Future<void> write(List<int> data) {
    if (_closed) {
      return Future.error(_closeReason ?? AdbCancelledException('The stream to "$service" is closed'));
    }
    if (data.isEmpty) return Future.value();
    final copy = Uint8List.fromList(data);
    _written += copy.length;
    final target = _written;
    return _writes = _writes.then((_) async {
      await opened;
      final socket = _socket;
      if (socket == null || _closed) {
        throw _closeReason ?? AdbCancelledException('The stream to "$service" is closed');
      }
      socket.add(copy);
      await socket.flush();
      _flushed = target;
      if (!_acks.isClosed) _acks.add(_flushed);
    });
  }

  @override
  Future<void> flush() => _writes;

  @override
  Future<void> close() async => _finish(null);

  void _finish(AdbException? reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    if (!_opened.isCompleted) {
      _opened.completeError(reason ?? AdbCancelledException('"$service" was closed while opening'));
    }
    unawaited(_subscription?.cancel());
    if (reason != null && reason is! AdbServiceUnavailableException) {
      _input.addError(reason);
    }
    unawaited(_input.close());
    unawaited(_acks.close());
    _socket?.destroy();
    if (!_done.isCompleted) _done.complete();
  }
}
