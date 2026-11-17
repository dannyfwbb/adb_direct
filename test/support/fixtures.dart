// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adb_direct/src/protocol/message.dart';

/// Who sent a recorded packet.
enum FixtureDirection {
  /// The client (the recorder) sent it to the device.
  toDevice,

  /// The device sent it.
  fromDevice,
}

/// One recorded packet.
final class FixturePacket {
  /// Creates a packet.
  const FixturePacket(this.direction, this.message, this.raw);

  /// Who sent it.
  final FixtureDirection direction;

  /// The message.
  final AdbMessage message;

  /// The bytes exactly as they crossed the wire: header (with the sender's
  /// checksum) and payload.
  final Uint8List raw;

  @override
  String toString() =>
      '${direction == FixtureDirection.toDevice ? '>' : '<'} $message';
}

/// A recorded exchange with a real adbd, from `test/fixtures/<name>.jsonl`.
///
/// See `test/fixtures/README.md` for the format.
final class Fixture {
  Fixture._(this.name, this.header, this.packets);

  /// Loads `test/fixtures/<name>.jsonl`.
  factory Fixture.load(String name) {
    final file = File('test/fixtures/$name.jsonl');
    final lines = file
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final header = (jsonDecode(lines.first) as Map).cast<String, Object?>();
    final packets = [
      for (final line in lines.skip(1))
        _packet((jsonDecode(line) as Map).cast<String, Object?>()),
    ];
    return Fixture._(name, header, List.unmodifiable(packets));
  }

  /// Every fixture under `test/fixtures/`, by name.
  static List<String> all() {
    final root = Directory('test/fixtures');
    final names = [
      for (final entity in root.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.jsonl'))
          entity.path
              .substring(root.path.length + 1)
              .replaceAll(r'\', '/')
              .replaceFirst(RegExp(r'\.jsonl$'), ''),
    ]..sort();
    return names;
  }

  /// The fixture's name, such as `shell/v2`.
  final String name;

  /// The header line: device, adbd version, date, note, and how it starts.
  final Map<String, Object?> header;

  /// The packets in the order they were sent or received.
  final List<FixturePacket> packets;

  /// Whether the recording starts at the TCP connection (`connection`) or
  /// on an already online connection (`online`).
  bool get startsOnline => header['starts'] == 'online';

  /// The host features the recorder announced, for fixtures that start
  /// online.
  String? get hostFeatures => header['host_features'] as String?;

  /// Packets the device sent.
  Iterable<AdbMessage> get fromDevice => packets
      .where((p) => p.direction == FixtureDirection.fromDevice)
      .map((p) => p.message);

  /// The raw bytes of every packet sent in [direction], concatenated.
  Uint8List rawBytes(FixtureDirection direction) => Uint8List.fromList([
    for (final packet in packets)
      if (packet.direction == direction) ...packet.raw,
  ]);

  /// Packets the recorder sent.
  Iterable<AdbMessage> get toDevice => packets
      .where((p) => p.direction == FixtureDirection.toDevice)
      .map((p) => p.message);

  static FixturePacket _packet(Map<String, Object?> json) {
    final direction = switch (json['dir']) {
      '>' => FixtureDirection.toDevice,
      '<' => FixtureDirection.fromDevice,
      final other => throw FormatException('Bad direction $other'),
    };
    final command = AdbCommand.values.firstWhere(
      (c) => c.wireName == json['cmd'],
      orElse: () => throw FormatException('Bad command ${json['cmd']}'),
    );
    final message = AdbMessage(
      command,
      json['arg0']! as int,
      json['arg1']! as int,
      _hex(json['data']! as String),
    );
    final raw = _hex(json['raw']! as String);
    _checkRaw(message, raw);
    return FixturePacket(direction, message, raw);
  }

  /// A fixture whose fields disagree with its raw bytes was edited by hand
  /// or recorded wrongly; refuse it.
  static void _checkRaw(AdbMessage message, Uint8List raw) {
    final header = ByteData.sublistView(raw);
    final consistent =
        raw.length == 24 + message.payload.length &&
        header.getUint32(0, Endian.little) == message.command.value &&
        header.getUint32(4, Endian.little) == message.arg0 &&
        header.getUint32(8, Endian.little) == message.arg1 &&
        header.getUint32(12, Endian.little) == message.payload.length &&
        _sameBytes(Uint8List.sublistView(raw, 24), message.payload);
    if (!consistent) {
      throw FormatException(
        'Fixture packet $message disagrees with its raw '
        'bytes',
      );
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _hex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
