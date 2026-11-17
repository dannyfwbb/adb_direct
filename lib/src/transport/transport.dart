// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';

/// Receives what a transport delivers. Exactly one of [AdbTransportListener.onClosed]
/// or [AdbTransportListener.onError] ends the delivery.
abstract interface class AdbTransportListener {
  /// Bytes arrived. The transport hands over ownership of [data].
  void onData(Uint8List data);

  /// The other side closed the connection.
  void onClosed();

  /// The connection failed. [error] is an `AdbException` with the OS error
  /// as its cause.
  void onError(Object error);
}

/// A bidirectional byte pipe to adbd.
///
/// Internal for now; a public, pluggable version (USB, tunnels) comes with
/// later work. Writes never block: the transport buffers what the network
/// cannot take yet. Flow control above it (ADB `OKAY`s) bounds that buffer.
abstract interface class AdbTransport {
  /// Starts delivering events to [listener]. Call once.
  void start(AdbTransportListener listener);

  /// Queues [bytes] for sending. The transport takes ownership.
  void write(Uint8List bytes);

  /// Bytes queued but not yet handed to the operating system.
  int get pendingWriteBytes;

  /// Sends what is queued, then closes. Completes when closed. A peer that
  /// stops reading cannot hold it open: after [drainTimeout] the rest is
  /// dropped and the connection destroyed.
  Future<void> close({required Duration drainTimeout});

  /// Drops the connection at once; queued bytes are lost. No more events
  /// are delivered.
  void destroy();

  /// Switches the live connection to TLS 1.3 as a client presenting the
  /// certificate in [context]; the server's certificate is accepted as it
  /// is (adb has nothing to check it against) and returned. Queued bytes
  /// go out in plain text first. [keyLog] receives the NSS key-log lines
  /// (the exporter secret among them). Throws [AdbException] on failure;
  /// the transport is destroyed then.
  Future<X509Certificate?> startTls({
    required SecurityContext context,
    void Function(String line)? keyLog,
  });
}
