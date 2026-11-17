// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// The pairing exchange after TLS, the same for both roles (AOSP
/// `pairing_connection.cpp`, `pairing_auth.cpp`, `aes_128_gcm.cpp`):
///
/// ```
/// password = code bytes ‖ TLS exporter("adb-label\0", 64)
/// > SPAKE2_MSG(32)                  < SPAKE2_MSG(32)
/// key = HKDF-SHA256(SPAKE2 key, info "adb pairing_auth aes-128-gcm key", 16)
/// > PEER_INFO(AES-128-GCM(8192))    < PEER_INFO(AES-128-GCM(8192))
/// ```
///
/// Each packet is `{u8 version = 1, u8 type, u32 size big-endian}` then
/// the payload (1 to 16384 bytes).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart' as pc;

import '../crypto/hkdf.dart';
import '../crypto/spake2.dart';
import '../errors.dart';
import '../protocol/byte_queue.dart';

/// Packet types.
@internal
abstract final class PairingPacket {
  /// The SPAKE2 message.
  static const int spake2Message = 0;

  /// The encrypted peer information.
  static const int peerInfo = 1;

  /// Header version.
  static const int version = 1;

  /// Header size.
  static const int headerLength = 6;

  /// The largest payload either side accepts.
  static const int maxPayload = 16384;
}

/// `PeerInfo`: one type byte and 8191 bytes of zero-padded data.
@internal
abstract final class PeerInfo {
  /// Its size on the wire, before encryption.
  static const int size = 8192;

  /// The host's public key in adb's text form.
  static const int rsaPublicKey = 0;

  /// The device's GUID (`persist.adb.wifi.guid`).
  static const int deviceGuid = 1;

  /// Builds one. [data] must leave room for a terminating NUL.
  static Uint8List build(int type, List<int> data) {
    if (data.length > size - 2) {
      throw ArgumentError.value(data.length, 'data', 'too long for PeerInfo');
    }
    return Uint8List(size)
      ..[0] = type
      ..setRange(1, 1 + data.length, data);
  }

  /// The type and the data up to its first NUL.
  static (int, String) parse(Uint8List info) {
    var end = info.indexOf(0, 1);
    if (end < 0) end = info.length;
    return (info[0], utf8.decode(info.sublist(1, end), allowMalformed: true));
  }
}

/// The TLS exporter label (with its NUL) and length adb binds to.
@internal
final List<int> pairingExporterLabel = [...utf8.encode('adb-label'), 0];

/// Exported bytes appended to the code.
@internal
const int pairingExporterLength = 64;

/// SPAKE2 names (with their NULs).
@internal
final List<int> pairingClientName = [...utf8.encode('adb pair client'), 0];

/// SPAKE2 names (with their NULs).
@internal
final List<int> pairingServerName = [...utf8.encode('adb pair server'), 0];

/// Reads pairing packets from a byte stream.
@internal
final class PairingReader {
  /// Reads from [input].
  PairingReader(Stream<List<int>> input) {
    _subscription = input.listen(
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

  late final StreamSubscription<List<int>> _subscription;
  final ByteQueue _buffer = ByteQueue();
  Completer<void>? _waiting;
  Object? _error;
  bool _closed = false;

  /// The next packet as (type, payload). Throws [AdbClosedException] when
  /// the stream ends first, [AdbPairingException] for a malformed header.
  Future<(int, Uint8List)> next() async {
    final header = await _take(PairingPacket.headerLength);
    final view = ByteData.sublistView(header);
    final version = view.getUint8(0);
    final type = view.getUint8(1);
    final size = view.getUint32(2);
    if (version != PairingPacket.version) {
      throw AdbPairingException('Pairing packet version $version');
    }
    if (size == 0 || size > PairingPacket.maxPayload) {
      throw AdbPairingException('Pairing packet of $size bytes');
    }
    return (type, await _take(size));
  }

  /// Stops reading.
  Future<void> cancel() => _subscription.cancel();

  Future<Uint8List> _take(int count) async {
    while (_buffer.length < count) {
      if (_error case final error?) {
        throw error is AdbException
            ? error
            : AdbClosedException('The pairing connection failed', cause: error);
      }
      if (_closed) {
        throw const AdbClosedException('The device closed the pairing session');
      }
      await (_waiting = Completer<void>()).future;
    }
    return _buffer.take(count);
  }

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }
}

/// One packet's bytes.
@internal
Uint8List pairingPacket(int type, List<int> payload) {
  final out = Uint8List(PairingPacket.headerLength + payload.length);
  ByteData.sublistView(out)
    ..setUint8(0, PairingPacket.version)
    ..setUint8(1, type)
    ..setUint32(2, payload.length);
  out.setRange(PairingPacket.headerLength, out.length, payload);
  return out;
}

/// AES-128-GCM with adb's nonces: a little-endian 64-bit counter, then
/// four zero bytes; one counter per direction, from zero.
@internal
final class PairingCipher {
  /// A cipher from the 64-byte SPAKE2 key.
  PairingCipher(List<int> spake2Key)
    : _key = Hkdf.derive(
        sha256,
        spake2Key,
        info: utf8.encode('adb pairing_auth aes-128-gcm key'),
        length: 16,
      );

  final Uint8List _key;
  int _sent = 0;
  int _received = 0;

  /// Encrypts the next outgoing message (ciphertext with its 16-byte tag).
  Uint8List encrypt(List<int> plain) => _run(true, _sent++, plain);

  /// Decrypts the next incoming message; null when it does not
  /// authenticate (another key: a wrong code).
  Uint8List? decrypt(List<int> sealed) {
    try {
      return _run(false, _received++, sealed);
    } on pc.InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Uint8List _run(bool encrypt, int counter, List<int> input) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(0, counter, Endian.little);
    final gcm = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        encrypt,
        pc.AEADParameters(pc.KeyParameter(_key), 128, nonce, Uint8List(0)),
      );
    return gcm.process(Uint8List.fromList(input));
  }
}

/// Runs the exchange for [role] over a TLS session: [password] is the code
/// followed by the exported bytes, [myInfo] the `PeerInfo` to send.
/// Returns the peer's decrypted `PeerInfo`.
///
/// Throws [AdbPairingException] with [AdbPairingFailure.wrongCode] when the
/// peer's info does not decrypt or the peer closes after ours (it could
/// not decrypt ours), and [AdbPairingFailure.protocol] for anything
/// malformed.
@internal
Future<Uint8List> runPairingExchange({
  required Spake2Role role,
  required List<int> password,
  required Uint8List myInfo,
  required PairingReader reader,
  required void Function(Uint8List bytes) write,
  Uint8List Function(int length)? random,
}) async {
  final alice = role == Spake2Role.alice;
  final spake = Spake2(
    role,
    myName: alice ? pairingClientName : pairingServerName,
    theirName: alice ? pairingServerName : pairingClientName,
    random: random,
  );
  write(
    pairingPacket(PairingPacket.spake2Message, spake.generateMessage(password)),
  );
  final (type, theirMessage) = await reader.next();
  if (type != PairingPacket.spake2Message) {
    throw AdbPairingException('Expected a SPAKE2 message, got type $type');
  }
  final Uint8List key;
  try {
    key = spake.processMessage(theirMessage);
  } on FormatException catch (e) {
    throw AdbPairingException('Invalid SPAKE2 message: ${e.message}', cause: e);
  }
  final cipher = PairingCipher(key);
  write(pairingPacket(PairingPacket.peerInfo, cipher.encrypt(myInfo)));

  final (int, Uint8List) answer;
  try {
    answer = await reader.next();
  } on AdbClosedException catch (e) {
    throw AdbPairingException(
      'The device closed the session after our key: most likely a wrong '
      'pairing code',
      reason: AdbPairingFailure.wrongCode,
      cause: e,
    );
  }
  final (infoType, sealed) = answer;
  if (infoType != PairingPacket.peerInfo) {
    throw AdbPairingException('Expected peer info, got type $infoType');
  }
  final info = cipher.decrypt(sealed);
  if (info == null) {
    throw const AdbPairingException(
      "The device's answer does not decrypt: wrong pairing code",
      reason: AdbPairingFailure.wrongCode,
    );
  }
  if (info.length != PeerInfo.size) {
    throw AdbPairingException('Peer info of ${info.length} bytes');
  }
  return info;
}
