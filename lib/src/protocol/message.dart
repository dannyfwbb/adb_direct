// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../errors.dart';
import 'byte_queue.dart';
import 'constants.dart';

/// The commands of the ADB message protocol.
enum AdbCommand {
  /// Obsolete; never valid on the wire. Kept so it can be named in errors.
  sync(0x434e5953),

  /// `CNXN`: announces version, payload limit and identity.
  connect(0x4e584e43),

  /// `AUTH`: RSA authentication.
  auth(0x48545541),

  /// `OPEN`: opens a stream to a service.
  open(0x4e45504f),

  /// `OKAY`: a stream is ready, or a write was consumed.
  okay(0x59414b4f),

  /// `CLSE`: a stream is closed.
  close(0x45534c43),

  /// `WRTE`: data on a stream.
  write(0x45545257),

  /// `STLS`: switch the connection to TLS.
  stls(0x534c5453);

  const AdbCommand(this.value);

  /// The value on the wire: four ASCII letters read as a little-endian unsigned 32-bit integer.
  final int value;

  /// The four letters, such as `CNXN`.
  String get wireName =>
      String.fromCharCodes([value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff]);

  /// The command for a wire [value], or null for an unknown one.
  static AdbCommand? fromValue(int value) {
    for (final command in values) {
      if (command.value == value) return command;
    }
    return null;
  }
}

/// The kinds of `AUTH` messages, carried in `arg0`.
enum AdbAuthType {
  /// Device → host: a random token to sign.
  token(1),

  /// Host → device: the token's signature.
  signature(2),

  /// Host → device: the public key, offered for the user to accept.
  rsaPublicKey(3);

  const AdbAuthType(this.value);

  /// The value in `arg0`.
  final int value;

  /// The type for [value], or null for an unknown one.
  static AdbAuthType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// One message of the ADB protocol: a command, two arguments and a payload.
///
/// Stream ids in `arg0` and `arg1` are relative to the sender: in a message we send, `arg0` is our id; in one we
/// receive, `arg0` is the device's.
@immutable
final class AdbMessage {
  /// Creates a message. Arguments must fit in 32 bits unsigned.
  ///
  /// A [Uint8List] payload is taken over, not copied (messages carry up to 1 MiB): the caller must not modify it
  /// afterwards. Any other list is copied.
  AdbMessage(this.command, this.arg0, this.arg1, [List<int>? payload]) : payload = _readOnly(payload) {
    _checkUint32(arg0, 'arg0');
    _checkUint32(arg1, 'arg1');
  }

  /// `CNXN(version, maxPayload, banner)`.
  factory AdbMessage.connect({
    required String banner,
    int version = AdbProtocol.version,
    int maxPayload = AdbProtocol.maxPayload,
  }) => AdbMessage(AdbCommand.connect, version, maxPayload, utf8.encode(banner));

  /// `AUTH(type, 0, data)`.
  factory AdbMessage.auth(AdbAuthType type, List<int> data) => AdbMessage(AdbCommand.auth, type.value, 0, data);

  /// `STLS(version, 0)`.
  factory AdbMessage.stls({int version = AdbProtocol.stlsVersion}) => AdbMessage(AdbCommand.stls, version, 0);

  /// `OPEN(localId, window, "service\0")`.
  ///
  /// [window] is our receive window when delayed acknowledgements are in use, and must be 0 otherwise. The service name
  /// is sent with a trailing NUL, as adb does; adbd strips it.
  factory AdbMessage.open({required int localId, required String service, int window = 0}) {
    _checkStreamId(localId, 'localId');
    return AdbMessage(AdbCommand.open, localId, window, [...utf8.encode(service), 0]);
  }

  /// `OKAY(localId, remoteId)`, with the number of bytes consumed as a little-endian `int32` payload when delayed
  /// acknowledgements are in use.
  factory AdbMessage.okay({required int localId, required int remoteId, int? acknowledged}) {
    _checkStreamId(localId, 'localId');
    _checkStreamId(remoteId, 'remoteId');
    if (acknowledged != null && (acknowledged < -0x80000000 || acknowledged > 0x7fffffff)) {
      throw RangeError.range(acknowledged, -0x80000000, 0x7fffffff, 'acknowledged');
    }
    final payload = acknowledged == null
        ? null
        : (ByteData(4)..setInt32(0, acknowledged, Endian.little)).buffer.asUint8List();
    return AdbMessage(AdbCommand.okay, localId, remoteId, payload);
  }

  /// `WRTE(localId, remoteId, data)`.
  factory AdbMessage.write({required int localId, required int remoteId, required List<int> data}) {
    _checkStreamId(localId, 'localId');
    _checkStreamId(remoteId, 'remoteId');
    return AdbMessage(AdbCommand.write, localId, remoteId, data);
  }

  /// `CLSE(localId, remoteId)`. [localId] is 0 when refusing an `OPEN`.
  factory AdbMessage.close({required int localId, required int remoteId}) {
    _checkStreamId(remoteId, 'remoteId');
    return AdbMessage(AdbCommand.close, localId, remoteId);
  }

  /// The command.
  final AdbCommand command;

  /// First argument; its meaning depends on [command].
  final int arg0;

  /// Second argument; its meaning depends on [command].
  final int arg1;

  /// The payload, as a read-only view. Empty when there is none.
  final Uint8List payload;

  /// The `int32` acknowledgement in an `OKAY` payload, or null when the payload is empty (no delayed acknowledgements).
  ///
  /// Throws [AdbProtocolException] when the payload has any other size. adbd drops such an `OKAY` and keeps the
  /// connection; callers should do the same rather than fail.
  int? get acknowledgedBytes {
    if (payload.isEmpty) return null;
    if (payload.length != 4) {
      throw AdbProtocolException('OKAY payload of ${payload.length} bytes; expected 0 or 4');
    }
    return ByteData.sublistView(payload).getInt32(0, Endian.little);
  }

  @override
  bool operator ==(Object other) =>
      other is AdbMessage &&
      other.command == command &&
      other.arg0 == arg0 &&
      other.arg1 == arg1 &&
      _bytesEqual(other.payload, payload);

  @override
  int get hashCode => Object.hash(command, arg0, arg1, Object.hashAll(payload));

  @override
  String toString() =>
      '${command.wireName}(0x${arg0.toRadixString(16)}, 0x${arg1.toRadixString(16)}, ${payload.length} bytes)';

  static final Uint8List _empty = Uint8List(0).asUnmodifiableView();

  static Uint8List _readOnly(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return _empty;
    final list = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return list.asUnmodifiableView();
  }
}

/// Encodes and decodes [AdbMessage]s.
abstract final class AdbMessageCodec {
  /// The bytes of [message]: the 24-byte header followed by the payload.
  ///
  /// Set [withChecksum] when the negotiated protocol version is below [AdbProtocol.versionSkipChecksum]; otherwise the
  /// checksum field is 0.
  static Uint8List encode(AdbMessage message, {required bool withChecksum}) {
    final payload = message.payload;
    final out = Uint8List(AdbProtocol.headerLength + payload.length);
    ByteData.sublistView(out, 0, AdbProtocol.headerLength)
      ..setUint32(0, message.command.value, Endian.little)
      ..setUint32(4, message.arg0, Endian.little)
      ..setUint32(8, message.arg1, Endian.little)
      ..setUint32(12, payload.length, Endian.little)
      ..setUint32(16, withChecksum ? checksum(payload) : 0, Endian.little)
      ..setUint32(20, message.command.value ^ 0xffffffff, Endian.little);
    out.setRange(AdbProtocol.headerLength, out.length, payload);
    return out;
  }

  /// The payload checksum of protocol version 1.0: the sum of the bytes, modulo 2³². (adb calls the field `data_crc32`;
  /// it is not a CRC.)
  static int checksum(List<int> payload) {
    var sum = 0;
    for (final byte in payload) {
      sum = (sum + byte) & 0xffffffff;
    }
    return sum;
  }
}

/// Called for a message whose command this library does not know.
///
/// [command] is the raw wire value, [length] the size of the payload that was skipped with it.
typedef AdbUnknownCommandCallback = void Function(int command, int length);

/// Turns a byte stream into [AdbMessage]s.
///
/// Feed chunks as they arrive with [add] and take complete messages with [next] or [drain]. Checksums are not verified,
/// as adbd does not verify them either.
///
/// Like adbd, the reader rejects only what breaks the framing: a wrong magic or a payload above [maxPayload]. A message
/// with an unknown command (or the obsolete `SYNC`) is skipped, reported to [onUnknownCommand], and reading continues,
/// so a newer device that adds a command does not lose the connection.
final class AdbMessageReader {
  /// Creates a reader that accepts payloads up to [maxPayload] bytes.
  AdbMessageReader({this.maxPayload = AdbProtocol.maxPayload, this.onUnknownCommand, this.onRawMessage});

  /// The largest payload accepted. A larger `data_length` is a protocol error.
  int maxPayload;

  /// Receives the messages that were skipped because their command is unknown.
  final AdbUnknownCommandCallback? onUnknownCommand;

  /// Receives the exact bytes (header and payload) of each message returned, for tracing and recording. Costs a copy
  /// per message when set.
  final void Function(Uint8List raw)? onRawMessage;

  final ByteQueue _buffer = ByteQueue();

  /// Bytes received but not yet returned as messages.
  int get bufferedLength => _buffer.length;

  /// Appends received bytes. The reader keeps a reference to [chunk]: do not modify it afterwards.
  void add(List<int> chunk) => _buffer.add(chunk);

  /// Every complete message buffered so far, in order.
  ///
  /// Lazy: each message is decoded as the iteration reaches it, and a protocol error is thrown at that point.
  Iterable<AdbMessage> drain() sync* {
    for (var message = next(); message != null; message = next()) {
      yield message;
    }
  }

  /// The next complete message, or null if more bytes are needed.
  ///
  /// Throws [AdbProtocolException] for a header with a wrong magic or an oversized payload. The reader is unusable
  /// after that: the stream can no longer be framed.
  ///
  /// The payload of the returned message may be a view of a received chunk and keeps that chunk alive as long as the
  /// message is referenced.
  AdbMessage? next() {
    while (_buffer.length >= AdbProtocol.headerLength) {
      final commandValue = _buffer.peekUint32Le(0);
      final magic = _buffer.peekUint32Le(20);
      if (magic != commandValue ^ 0xffffffff) {
        throw AdbProtocolException(
          'Bad message magic 0x${magic.toRadixString(16)} for command 0x${commandValue.toRadixString(16)}',
        );
      }
      final length = _buffer.peekUint32Le(12);
      if (length > maxPayload) {
        throw AdbProtocolException(
          'Payload of $length bytes for command 0x${commandValue.toRadixString(16)} exceeds the limit of $maxPayload',
        );
      }
      if (_buffer.length < AdbProtocol.headerLength + length) return null;
      final command = AdbCommand.fromValue(commandValue);
      if (command == null || command == AdbCommand.sync) {
        _buffer.skip(AdbProtocol.headerLength + length);
        onUnknownCommand?.call(commandValue, length);
        continue;
      }
      final arg0 = _buffer.peekUint32Le(4);
      final arg1 = _buffer.peekUint32Le(8);
      final onRaw = onRawMessage;
      if (onRaw == null) {
        _buffer.skip(AdbProtocol.headerLength);
        return AdbMessage(command, arg0, arg1, _buffer.take(length));
      }
      final raw = Uint8List(AdbProtocol.headerLength + length)
        ..setRange(0, AdbProtocol.headerLength, _buffer.take(AdbProtocol.headerLength));
      final payload = _buffer.take(length);
      raw.setRange(AdbProtocol.headerLength, raw.length, payload);
      onRaw(raw);
      return AdbMessage(command, arg0, arg1, payload);
    }
    return null;
  }
}

void _checkUint32(int value, String name) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff, name);
  }
}

void _checkStreamId(int value, String name) {
  if (value <= 0 || value > 0xffffffff) {
    throw RangeError.range(value, 1, 0xffffffff, name);
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
