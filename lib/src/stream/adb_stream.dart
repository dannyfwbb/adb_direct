// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../clock.dart';
import '../errors.dart';
import '../protocol/message.dart';

/// A byte stream to one service on the device, such as `shell:ls` or
/// `sync:`.
///
/// Read with [input]; write with [write]. Both directions apply ADB flow
/// control: the device is told it may send more only when the [input]
/// listener has received what came (pause the subscription to slow the
/// device down), and [write] completes when the data is on its way within
/// the device's window.
///
/// ADB streams have no half-close: [close] ends both directions, and so does
/// the device closing its end.
final class AdbStream {
  /// Wraps an endpoint; streams are created by the connection.
  @internal
  AdbStream(this._endpoint);

  final StreamEndpoint _endpoint;

  /// The service name sent in `OPEN`.
  String get service => _endpoint.service;

  /// Bytes from the device. Single subscription. Ends when the stream
  /// closes; carries an [AdbException] error first when the connection
  /// failed. Cancelling the subscription closes the stream.
  Stream<Uint8List> get input => _endpoint.input;

  /// Completes when the stream is open, or fails when the device refused it
  /// ([AdbServiceUnavailableException]), it was closed first
  /// ([AdbCancelledException]) or the connection failed.
  Future<void> get opened => _endpoint.opened;

  /// Completes when the stream is closed, by either side or by a failure.
  /// Never fails: see [closeReason] for why it closed.
  Future<void> get done => _endpoint.done;

  /// Whether the stream is closed.
  bool get isClosed => _endpoint.isClosed;

  /// Why the stream closed when it was not a normal close by either side:
  /// the connection failed, or the device refused to open it.
  AdbException? get closeReason => _endpoint.closeReason;

  /// Bytes of our writes the device has acknowledged: what it has taken,
  /// as opposed to what [write] handed to the connection. Use it for
  /// progress that means "arrived".
  int get acknowledgedBytes => _endpoint.acknowledgedBytes;

  /// Sends [data] to the device.
  ///
  /// Splits it to the payload limit and sends within the flow-control
  /// window. Completes when the last piece is handed to the connection
  /// (not when the device has processed it). Writes are sent in order.
  /// Fails with the reason when the stream closes first.
  Future<void> write(List<int> data) => _endpoint.write(data);

  /// Completes when the device has acknowledged every byte written before
  /// this call (later writes do not delay it). Fails like [write] when the
  /// stream closes first.
  Future<void> flush() => _endpoint.flush();

  /// [acknowledgedBytes] each time the device acknowledges more, for
  /// progress that means "arrived". Broadcast; ends when the stream closes.
  Stream<int> get acknowledgements => _endpoint.acknowledgements;

  /// Closes the stream in both directions. Pending writes fail with
  /// [AdbCancelledException]. Data already received stays readable.
  Future<void> close() => _endpoint.close();

  @override
  String toString() => 'AdbStream($service${isClosed ? ', closed' : ''})';
}

/// What a stream endpoint needs from its connection.
@internal
abstract interface class StreamHost {
  /// Sends a message on the connection.
  void send(AdbMessage message);

  /// The negotiated payload limit.
  int get maxPayload;

  /// Whether delayed acknowledgements are in use.
  bool get delayedAck;

  /// The clock for acknowledgement timers.
  AdbClock get clock;

  /// How long an acknowledgement may take before the device is checked.
  Duration get acknowledgementTimeout;

  /// The endpoint with [localId] is finished; forget it.
  void endpointFinished(int localId);

  /// An acknowledgement on [endpoint] is overdue.
  void acknowledgementOverdue(StreamEndpoint endpoint);
}

enum _State { opening, open, closed }

/// The state machine behind an [AdbStream]: the connection routes messages
/// here. Internal.
@internal
final class StreamEndpoint {
  /// Creates an endpoint that is opening; the connection sends the `OPEN`.
  StreamEndpoint(this._host, {required this.localId, required this.service}) {
    // Synchronous delivery: when add() returns, an active listener has
    // received the data, so it can be acknowledged at once; a paused or
    // missing listener leaves it unacknowledged until it resumes.
    _input = StreamController<Uint8List>(
      sync: true,
      onListen: _flushAcknowledgements,
      onResume: _flushAcknowledgements,
      onCancel: close,
    );
    _armAcknowledgementTimer();
  }

  final StreamHost _host;

  /// Our id for this stream.
  final int localId;

  /// The service name sent in `OPEN`.
  final String service;

  late final StreamController<Uint8List> _input;
  final Completer<void> _opened = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Queue<_PendingWrite> _writes = Queue<_PendingWrite>();

  _State _state = _State.opening;
  int _remoteId = 0;
  bool _closeWhenOpened = false;
  AdbException? _closeReason;

  // Sending: classic mode allows one write in flight; delayed mode allows
  // writes while the device's budget is positive.
  bool _readyToSend = false;
  int _sendBudget = 0;
  int _inFlight = 0;
  int _acknowledged = 0;

  // Receiving: data received from the device and not yet acknowledged.
  int _unacknowledgedWrites = 0;
  int _unacknowledgedBytes = 0;

  Timer? _acknowledgementTimer;
  int _queued = 0;
  final List<(int, Completer<void>)> _flushes = [];
  final StreamController<int> _acknowledgements =
      StreamController<int>.broadcast();

  /// See [AdbStream.input].
  Stream<Uint8List> get input => _input.stream;

  /// See [AdbStream.opened].
  Future<void> get opened => _opened.future;

  /// See [AdbStream.done].
  Future<void> get done => _done.future;

  /// See [AdbStream.isClosed].
  bool get isClosed => _state == _State.closed;

  /// See [AdbStream.closeReason].
  AdbException? get closeReason => _closeReason;

  /// See [AdbStream.acknowledgedBytes].
  int get acknowledgedBytes => _acknowledged;

  /// Whether a message from the device's stream [remoteId] belongs to this
  /// stream: any id while opening (the first `OKAY` tells it), the known
  /// one after.
  bool acceptsFrom(int remoteId) => _remoteId == 0 || _remoteId == remoteId;

  /// See [AdbStream.write].
  Future<void> write(List<int> data) {
    if (_state == _State.closed) {
      return Future.error(
        _closeReason ??
            AdbClosedException('The stream to "$service" is closed'),
      );
    }
    if (data.isEmpty) return Future.value();
    final pending = _PendingWrite(
      data is Uint8List ? data : Uint8List.fromList(data),
    );
    _queued += pending.data.length;
    _writes.add(pending);
    _pump();
    return pending.completer.future;
  }

  /// See [AdbStream.flush].
  Future<void> flush() {
    if (_state == _State.closed) {
      return Future.error(
        _closeReason ??
            AdbClosedException('The stream to "$service" is closed'),
      );
    }
    final target = _queued;
    if (_acknowledged >= target) return Future.value();
    final completer = Completer<void>();
    _flushes.add((target, completer));
    return completer.future;
  }

  /// See [AdbStream.acknowledgements].
  Stream<int> get acknowledgements => _acknowledgements.stream;

  void _completeFlushes() {
    _flushes.removeWhere((entry) {
      final (target, completer) = entry;
      if (_acknowledged < target) return false;
      completer.complete();
      return true;
    });
  }

  /// See [AdbStream.close].
  Future<void> close() {
    const reason = AdbCancelledException('The stream was closed by the caller');
    switch (_state) {
      case _State.closed:
        break;
      case _State.opening:
        // The device's id is not known yet: close as soon as it answers.
        _closeWhenOpened = true;
        _finish(reason, normal: true);
      case _State.open:
        _state = _State.closed;
        _host.send(AdbMessage.close(localId: localId, remoteId: _remoteId));
        _finish(reason, normal: true);
    }
    return done;
  }

  /// An `OKAY` from the device: the answer to `OPEN`, or an acknowledgement
  /// of our writes once open.
  void handleOkay(AdbMessage okay) {
    final int? acknowledged;
    try {
      acknowledged = okay.acknowledgedBytes;
    } on AdbProtocolException {
      // adbd drops an OKAY with a malformed payload; so do we.
      return;
    }
    switch (_state) {
      case _State.open:
        _handleAcknowledgement(acknowledged);
      case _State.opening:
        _handleOpened(okay.arg0, acknowledged);
      case _State.closed:
        if (_closeWhenOpened) {
          // Closed by the caller while opening: now the device's id is
          // known, tell it.
          _closeWhenOpened = false;
          _host
            ..send(AdbMessage.close(localId: localId, remoteId: okay.arg0))
            ..endpointFinished(localId);
        }
    }
  }

  /// A `WRTE` with data for us.
  void handleData(AdbMessage write) {
    if (_state != _State.open) return;
    final data = write.payload;
    // With synchronous delivery, an active listener receives the data inside
    // add(); an absent or paused one leaves it buffered until it resumes.
    final delivered = _input.hasListener && !_input.isPaused;
    _unacknowledgedWrites++;
    _unacknowledgedBytes += data.length;
    _input.add(data);
    if (delivered) _sendAcknowledgements();
  }

  /// A `CLSE` from the device.
  void handleClose() {
    switch (_state) {
      case _State.closed:
        if (_closeWhenOpened) {
          // Closed by the caller while opening, and the device refused or
          // closed it: nothing left to tell the device.
          _closeWhenOpened = false;
          _host.endpointFinished(localId);
        }
      case _State.opening:
        _finish(
          AdbServiceUnavailableException(
            'The device refused to open "$service"',
            service: service,
          ),
        );
      case _State.open:
        _finish(
          AdbClosedException('The device closed the stream to "$service"'),
          normal: true,
        );
    }
  }

  /// The connection failed or was closed.
  void handleConnectionEnd(AdbException reason) {
    _closeWhenOpened = false;
    if (_state != _State.closed) _finish(reason);
  }

  void _handleOpened(int remoteId, int? window) {
    if (_host.delayedAck && window == null) {
      // The device must announce its window; without it nothing could be
      // sent. Treat it like adbd treats a malformed OKAY: ignore it.
      return;
    }
    _remoteId = remoteId;
    if (_host.delayedAck) {
      _sendBudget = window!;
    } else {
      _readyToSend = true;
    }
    _state = _State.open;
    _disarmAcknowledgementTimer();
    _opened.complete();
    _pump();
    _completeFlushes();
  }

  void _handleAcknowledgement(int? acknowledged) {
    if (_host.delayedAck) {
      final bytes = acknowledged ?? 0;
      _sendBudget += bytes;
      _inFlight -= bytes;
      _acknowledged += bytes;
    } else {
      _readyToSend = true;
      _acknowledged += _inFlight;
      _inFlight = 0;
    }
    _disarmAcknowledgementTimer();
    if (_inFlight > 0) _armAcknowledgementTimer();
    _acknowledgements.add(_acknowledged);
    _pump();
    _completeFlushes();
  }

  void _pump() {
    final limit = _host.maxPayload;
    while (_state == _State.open && _writes.isNotEmpty) {
      final allowed = _host.delayedAck ? _sendBudget > 0 : _readyToSend;
      if (!allowed) return;
      final pending = _writes.first;
      final remaining = pending.data.length - pending.offset;
      final size = remaining < limit ? remaining : limit;
      final chunk = Uint8List.sublistView(
        pending.data,
        pending.offset,
        pending.offset + size,
      );
      pending.offset += size;
      _inFlight += size;
      if (_host.delayedAck) {
        _sendBudget -= size;
      } else {
        _readyToSend = false;
      }
      if (_acknowledgementTimer == null) _armAcknowledgementTimer();
      _host.send(
        AdbMessage.write(localId: localId, remoteId: _remoteId, data: chunk),
      );
      // Sending can end the stream (a tracer closing it, a failing
      // transport): the queue is then already failed and emptied.
      if (_state != _State.open) return;
      if (pending.offset == pending.data.length) {
        _writes.removeFirst();
        pending.completer.complete();
      }
    }
  }

  /// Acknowledges what was held back once the listener is there and not
  /// paused (buffered events are then delivered).
  void _flushAcknowledgements() {
    if (!_input.hasListener || _input.isPaused) return;
    _sendAcknowledgements();
  }

  /// Acknowledges everything received so far.
  void _sendAcknowledgements() {
    if (_state != _State.open || _unacknowledgedWrites == 0) return;
    final writes = _unacknowledgedWrites;
    final bytes = _unacknowledgedBytes;
    _unacknowledgedWrites = 0;
    _unacknowledgedBytes = 0;
    if (_host.delayedAck) {
      _host.send(
        AdbMessage.okay(
          localId: localId,
          remoteId: _remoteId,
          acknowledged: bytes,
        ),
      );
    } else {
      for (var i = 0; i < writes && _state == _State.open; i++) {
        _host.send(AdbMessage.okay(localId: localId, remoteId: _remoteId));
      }
    }
  }

  void _armAcknowledgementTimer() {
    _acknowledgementTimer?.cancel();
    _acknowledgementTimer = _host.clock.timer(_host.acknowledgementTimeout, () {
      _acknowledgementTimer = null;
      if (_state == _State.closed) return;
      _host.acknowledgementOverdue(this);
      // Still waiting: check again after another period.
      if (_state != _State.closed) _armAcknowledgementTimer();
    });
  }

  void _disarmAcknowledgementTimer() {
    _acknowledgementTimer?.cancel();
    _acknowledgementTimer = null;
  }

  /// Ends the stream. [normal] closes (by either side) leave [closeReason]
  /// null; failures set it. [opened] fails either way if still pending.
  void _finish(AdbException reason, {bool normal = false}) {
    _state = _State.closed;
    if (!normal) _closeReason = reason;
    _disarmAcknowledgementTimer();
    if (!_opened.isCompleted) {
      _opened.completeError(reason);
      // Nobody may be listening to [opened] (a caller that only reads);
      // keep the error from being reported as unhandled.
      unawaited(_opened.future.then((_) {}, onError: (Object _) {}));
    }
    while (_writes.isNotEmpty) {
      _writes.removeFirst().completer.completeError(reason);
    }
    for (final (_, completer) in _flushes) {
      completer.completeError(reason);
    }
    _flushes.clear();
    unawaited(_acknowledgements.close());
    if (!normal) _input.addError(reason);
    unawaited(_input.close());
    if (!_closeWhenOpened) _host.endpointFinished(localId);
    if (!_done.isCompleted) _done.complete();
  }
}

final class _PendingWrite {
  _PendingWrite(this.data);

  final Uint8List data;
  int offset = 0;
  final Completer<void> completer = Completer<void>();
}
