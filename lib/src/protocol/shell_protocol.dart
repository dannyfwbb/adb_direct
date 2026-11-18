// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import '../errors.dart';
import 'byte_queue.dart';
import 'constants.dart';

/// Packet ids of shell protocol v2 (adbd's `shell_protocol.h`).
enum ShellPacketId {
  /// Host → device: bytes for the command's stdin.
  stdin,

  /// Device → host: the command's stdout (or the PTY's output).
  stdout,

  /// Device → host: the command's stderr.
  stderr,

  /// Device → host: one byte, the exit status.
  exit,

  /// Host → device: no more stdin (EOF for a raw command; ignored by a PTY).
  closeStdin,

  /// Host → device: ASCII `"<rows>x<cols>,<xpixels>x<ypixels>"`.
  windowSizeChange;

  /// The id on the wire.
  int get value => index;

  /// The id for a wire [value], or null for one this library does not know.
  static ShellPacketId? fromValue(int value) => value < values.length ? values[value] : null;
}

/// One packet of shell protocol v2.
final class ShellPacket {
  /// Creates a packet.
  const ShellPacket(this.id, this.data);

  /// The packet's id; null for one this library does not know (skipped by readers).
  final ShellPacketId? id;

  /// The packet's data.
  final Uint8List data;
}

/// Frames shell protocol v2: `{u8 id, u32 length (little-endian), data}`.
///
/// Packets are carried inside a stream's data and may be split across, or share, the stream's messages.
abstract final class ShellProtocol {
  /// Size of a packet header.
  static const int headerLength = 5;

  /// A packet with [id] and [data].
  static Uint8List encode(ShellPacketId id, List<int> data) {
    final out = Uint8List(headerLength + data.length)..[0] = id.value;
    ByteData.sublistView(out).setUint32(1, data.length, Endian.little);
    out.setRange(headerLength, out.length, data);
    return out;
  }
}

/// Turns stream data into [ShellPacket]s.
///
/// adbd's packets fit its 1 MiB buffer; a longer one means the stream is not shell protocol and is refused instead of
/// buffered without bound.
final class ShellPacketReader {
  /// The largest packet data accepted.
  static const int maxPacketLength = AdbProtocol.maxPayload;

  final ByteQueue _buffer = ByteQueue();

  /// Appends stream data.
  void add(List<int> data) => _buffer.add(data);

  /// Every complete packet buffered so far.
  Iterable<ShellPacket> drain() sync* {
    while (_buffer.length >= ShellProtocol.headerLength) {
      final length = _buffer.peekUint32Le(1);
      if (length > maxPacketLength) {
        throw AdbProtocolException('Shell protocol packet of $length bytes exceeds $maxPacketLength');
      }
      if (_buffer.length < ShellProtocol.headerLength + length) return;
      final id = ShellPacketId.fromValue(_buffer.byteAt(0));
      _buffer.skip(ShellProtocol.headerLength);
      yield ShellPacket(id, _buffer.take(length));
    }
  }

  /// Bytes of an incomplete packet left over.
  int get bufferedLength => _buffer.length;
}
