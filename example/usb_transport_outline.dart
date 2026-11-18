// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

// An outline of a USB transport, to show what [AdbTransport] asks of one.
// Not part of the package: USB needs libusb (desktop) or Android's USB
// host API, which belong in a package of their own. [UsbBulkPipe] stands
// for whatever such a package offers: the adb interface's two bulk
// endpoints (class 0xff, subclass 0x42, protocol 0x01), claimed.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:adb_direct/adb_direct.dart';

/// The two bulk endpoints of an adb interface.
abstract interface class UsbBulkPipe {
  /// Reads up to [maxLength] bytes from the IN endpoint; an empty result
  /// means the device went away.
  Future<Uint8List> read(int maxLength);

  /// Writes [data] to the OUT endpoint. adbd wants each ADB message in
  /// its own transfers: the 24-byte header, then the payload.
  Future<void> write(Uint8List data);

  /// Releases the interface.
  Future<void> close();
}

/// [AdbTransport] over [UsbBulkPipe].
final class UsbTransport implements AdbTransport {
  UsbTransport(this._pipe);

  final UsbBulkPipe _pipe;
  final Queue<Uint8List> _out = Queue();
  AdbTransportListener? _listener;
  bool _writing = false;
  bool _ended = false;
  int _pending = 0;

  @override
  int get pendingWriteBytes => _pending;

  @override
  void start(AdbTransportListener listener) {
    _listener = listener;
    unawaited(_readLoop());
  }

  Future<void> _readLoop() async {
    while (!_ended) {
      final Uint8List data;
      try {
        data = await _pipe.read(16384);
      } on Object catch (e) {
        _end(error: AdbClosedException('USB read failed', cause: e));
        return;
      }
      if (data.isEmpty) {
        _end();
        return;
      }
      _listener!.onData(data);
    }
  }

  @override
  void write(Uint8List bytes) {
    if (_ended || bytes.isEmpty) return;
    _out.add(bytes);
    _pending += bytes.length;
    if (!_writing) unawaited(_drain());
  }

  Future<void> _drain() async {
    _writing = true;
    while (_out.isNotEmpty && !_ended) {
      final chunk = _out.removeFirst();
      try {
        await _pipe.write(chunk);
      } on Object catch (e) {
        _end(error: AdbClosedException('USB write failed', cause: e));
        return;
      }
      _pending -= chunk.length;
    }
    _writing = false;
  }

  @override
  Future<void> close({required Duration drainTimeout}) async {
    final deadline = DateTime.now().add(drainTimeout);
    while (_pending > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    destroy();
  }

  @override
  void destroy() {
    if (_ended) return;
    _ended = true;
    _out.clear();
    _pending = 0;
    unawaited(_pipe.close());
  }

  /// USB has no TLS: wireless debugging is a network feature.
  @override
  Never startTls({required Object context, Object? keyLog}) =>
      throw const AdbNotSupportedException('USB links have no TLS');

  void _end({AdbException? error}) {
    if (_ended) return;
    final listener = _listener;
    destroy();
    if (error == null) {
      listener?.onClosed();
    } else {
      listener?.onError(error);
    }
  }
}

/// How it would be used, given a pipe from a USB package.
Future<void> connectOverUsb(UsbBulkPipe pipe, AdbKeyPair key) async {
  final adb = await AdbConnection.connectTransport(() async => UsbTransport(pipe), key: key);
  print((await adb.shell.run('getprop ro.product.model')).stdoutText);
  await adb.close();
}
