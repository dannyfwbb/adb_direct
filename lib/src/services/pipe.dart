// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../stream/adb_stream.dart';

/// Copies bytes both ways between a device [stream] and a local [socket] until either side ends, then closes both.
/// Completes when both are done.
///
/// Each direction waits for its sink before reading more: a write to the device completes when it was sent (or
/// acknowledged, with delayed acknowledgements), a write to the socket when it was flushed. So a slow side slows the
/// other down instead of filling memory, and the device's flow control reaches the local peer.
@internal
Future<void> pipe(AdbStream stream, Socket socket) {
  final done = Completer<void>();
  var finished = false;
  late final StreamSubscription<Uint8List> fromSocket;
  late final StreamSubscription<Uint8List> fromDevice;

  void finish() {
    if (finished) return;
    finished = true;
    unawaited(fromSocket.cancel());
    unawaited(fromDevice.cancel());
    unawaited(stream.close());
    socket.destroy();
    done.complete();
  }

  fromSocket = socket.listen(
    (data) {
      fromSocket.pause();
      unawaited(
        stream.write(data).then((_) {
          if (!finished) fromSocket.resume();
        }, onError: (Object _) => finish()),
      );
    },
    onError: (Object _) => finish(),
    onDone: finish,
    cancelOnError: true,
  );
  fromDevice = stream.input.listen(
    (data) {
      socket.add(data);
      fromDevice.pause();
      unawaited(
        socket.flush().then((_) {
          if (!finished) fromDevice.resume();
        }, onError: (Object _) => finish()),
      );
    },
    onError: (Object _) => finish(),
    onDone: finish,
    cancelOnError: true,
  );
  // A write error on the socket also completes `done` with an error.
  socket.done.then((_) {}, onError: (Object _) => finish()).ignore();
  return done.future;
}
