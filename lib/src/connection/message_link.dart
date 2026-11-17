// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../clock.dart';
import '../errors.dart';
import '../protocol/message.dart';
import '../trace.dart';
import '../transport/transport.dart';

/// Receives messages once a [MessageLink] is routed.
abstract interface class MessageHandler {
  /// A message arrived.
  void onMessage(AdbMessage message);

  /// The link is gone for [reason]; no more messages follow.
  void onLinkClosed(AdbException reason);
}

/// ADB messages over an [AdbTransport]: framing both ways, checksums by
/// protocol version, tracing, and two ways of receiving.
///
/// During the handshake, code pulls messages one at a time with [next] and a
/// deadline. Once online, [route] hands every message to a handler as it
/// arrives. Messages received in between are kept and delivered in order.
final class MessageLink implements AdbTransportListener {
  /// Wraps `transport`. Call [start] to begin receiving.
  MessageLink(this._transport, {required this.clock, this.tracer}) {
    _reader = AdbMessageReader(
      onUnknownCommand: (command, length) => _note(
        'Skipped a message with unknown command '
        '0x${command.toRadixString(16)} ($length bytes)',
      ),
      onRawMessage: tracer == null ? null : _traceIncoming,
    );
  }

  final AdbTransport _transport;

  /// The clock for deadlines.
  final AdbClock clock;

  /// Receives every message and note, if set.
  final AdbTracer? tracer;

  late final AdbMessageReader _reader;
  final Queue<AdbMessage> _inbox = Queue<AdbMessage>();
  Completer<void>? _waiter;
  MessageHandler? _handler;
  AdbException? _failure;

  /// Whether outgoing messages carry payload checksums. True until both
  /// sides have agreed on version `0x01000001`: AOSP's host computes them
  /// for everything sent before the device's `CNXN`.
  bool withChecksum = true;

  /// Why the link ended, or null while it works.
  AdbException? get failure => _failure;

  /// The largest payload accepted from the device.
  set maxIncomingPayload(int value) => _reader.maxPayload = value;

  /// Begins receiving.
  void start() => _transport.start(this);

  /// Sends [message].
  void send(AdbMessage message) {
    if (_failure != null) return;
    final bytes = AdbMessageCodec.encode(message, withChecksum: withChecksum);
    _trace(true, message, bytes);
    _transport.write(bytes);
  }

  /// The next message, failing with [onTimeout]'s exception when none
  /// arrives within [timeout], and with the link's failure when it ends.
  Future<AdbMessage> next({
    required Duration timeout,
    required AdbException Function() onTimeout,
  }) async {
    if (_handler != null) throw StateError('MessageLink is routed');
    var timedOut = false;
    final timer = clock.timer(timeout, () {
      timedOut = true;
      _wake();
    });
    try {
      while (true) {
        if (_inbox.isNotEmpty) return _inbox.removeFirst();
        if (_failure case final failure?) throw failure;
        if (timedOut) throw onTimeout();
        final waiter = _waiter = Completer<void>();
        await waiter.future;
      }
    } finally {
      timer.cancel();
    }
  }

  /// Delivers every message, queued ones first, to [handler] from now on.
  void route(MessageHandler handler) {
    if (_handler != null) throw StateError('MessageLink is already routed');
    _handler = handler;
    while (_inbox.isNotEmpty && _handler == handler) {
      handler.onMessage(_inbox.removeFirst());
    }
    if (_failure case final failure?) handler.onLinkClosed(failure);
  }

  /// Ends the link because of [reason] and drops the connection.
  void fail(AdbException reason) {
    if (_failure != null) return;
    _failure = reason;
    _note('Link closed: ${reason.message}');
    _transport.destroy();
    _wake();
    _handler?.onLinkClosed(reason);
  }

  /// Sends what is queued (for at most [drainTimeout]) and closes the
  /// connection; the link ends with [reason].
  Future<void> close(
    AdbException reason, {
    Duration drainTimeout = const Duration(seconds: 10),
  }) async {
    if (_failure != null) return;
    _failure = reason;
    _note('Link closed: ${reason.message}');
    _wake();
    _handler?.onLinkClosed(reason);
    await _transport.close(drainTimeout: drainTimeout);
  }

  /// Writes a note to the tracer.
  void note(String message) => _note(message);

  /// Switches the transport to TLS (after `STLS`); see
  /// [AdbTransport.startTls].
  Future<X509Certificate?> startTls({
    required SecurityContext context,
    void Function(String line)? keyLog,
  }) {
    note('TLS: handshake');
    return _transport.startTls(context: context, keyLog: keyLog);
  }

  @override
  void onData(Uint8List data) {
    if (_failure != null) return;
    try {
      _reader.add(data);
      for (final message in _reader.drain()) {
        if (_failure != null) return;
        _traceIncomingMessage(message);
        final handler = _handler;
        if (handler != null) {
          handler.onMessage(message);
        } else {
          _inbox.add(message);
          _wake();
        }
      }
    } on AdbProtocolException catch (e) {
      fail(e);
    }
  }

  @override
  void onClosed() {
    if (_failure != null) return;
    _failure = const AdbClosedException('The device closed the connection');
    _note('Link closed by the device');
    _wake();
    _handler?.onLinkClosed(_failure!);
  }

  @override
  void onError(Object error) {
    if (_failure != null) return;
    _failure = error is AdbException
        ? error
        : AdbClosedException('The connection failed', cause: error);
    _note('Link failed: $error');
    _wake();
    _handler?.onLinkClosed(_failure!);
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _note(String message) =>
      tracer?.call(AdbNoteTrace(at: clock.elapsed, message: message));

  /// The raw bytes of the message the reader is about to return; set by
  /// the reader's callback just before the message comes out of `drain`.
  Uint8List? _lastRaw;

  void _traceIncoming(Uint8List raw) => _lastRaw = raw;

  void _traceIncomingMessage(AdbMessage message) {
    final raw = _lastRaw;
    _lastRaw = null;
    if (raw != null) _trace(false, message, raw);
  }

  void _trace(bool outgoing, AdbMessage message, Uint8List raw) {
    tracer?.call(
      AdbPacketTrace(
        at: clock.elapsed,
        outgoing: outgoing,
        command: message.command.wireName,
        arg0: message.arg0,
        arg1: message.arg1,
        payload: message.payload,
        raw: raw,
      ),
    );
  }
}
