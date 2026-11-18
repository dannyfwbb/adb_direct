// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// Receives what a connection does, for logs, debugging and recording.
///
/// Called synchronously on the event loop; keep it cheap. Payloads include public keys and command output, never
/// private key material.
typedef AdbTracer = void Function(AdbTraceEvent event);

/// One traced event.
sealed class AdbTraceEvent {
  const AdbTraceEvent(this.at);

  /// When it happened, on the connection's clock (monotonic; only differences are meaningful).
  final Duration at;
}

/// A message sent or received.
final class AdbPacketTrace extends AdbTraceEvent {
  /// Creates the event.
  const AdbPacketTrace({
    required Duration at,
    required this.outgoing,
    required this.command,
    required this.arg0,
    required this.arg1,
    required this.payload,
    required this.raw,
  }) : super(at);

  /// Whether we sent it.
  final bool outgoing;

  /// The four-letter command, such as `WRTE`, or `0x…` for an unknown one.
  final String command;

  /// First argument.
  final int arg0;

  /// Second argument.
  final int arg1;

  /// The payload. Do not modify it.
  final Uint8List payload;

  /// The whole message as it crossed the wire, header included. Do not modify it.
  final Uint8List raw;

  @override
  String toString() =>
      "${outgoing ? '>' : '<'} $command(0x${arg0.toRadixString(16)}, 0x${arg1.toRadixString(16)}, ${payload.length} bytes)";
}

/// A change of connection state, or anything else worth a log line.
final class AdbNoteTrace extends AdbTraceEvent {
  /// Creates the event.
  const AdbNoteTrace({required Duration at, required this.message}) : super(at);

  /// What happened.
  final String message;

  @override
  String toString() => message;
}
