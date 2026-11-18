// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Records a connection to a real adbd as a fixture for the tests.
///
/// ```
/// dart run tool/record_fixture.dart HOST PORT KEY_PEM OUT.jsonl \
///   "DEVICE" "ADBD VERSION" "NOTE" SERVICE [--online]
/// ```
///
/// Connects with the key, opens SERVICE, reads until the device closes it and waits half a second for late messages.
/// Every packet is written with its raw bytes (format: test/fixtures/README.md). With `--online` the handshake is left
/// out and the fixture starts on the open connection.
library;

import 'dart:convert';
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

Future<void> main(List<String> args) async {
  if (args.length < 8) {
    stderr.writeln('usage: record_fixture HOST PORT KEY OUT DEVICE ADBD NOTE SERVICE [--online]');
    exitCode = 64;
    return;
  }
  final [host, port, keyPath, out, device, adbd, note, service, ...rest] = args;
  final online = rest.contains('--online');
  final key = AdbKeyPair.fromPem(File(keyPath).readAsStringSync());
  final packets = <AdbPacketTrace>[];
  var recording = !online;
  final adb = await AdbConnection.connect(
    host,
    int.parse(port),
    key: key,
    options: const AdbConnectOptions(livenessInterval: null),
    tracer: (event) {
      if (event is AdbPacketTrace && recording) packets.add(event);
    },
  );
  recording = true;
  final stream = await adb.open(service);
  await stream.input.drain<void>();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await adb.close();

  String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final lines = [
    jsonEncode({
      'fixture': out.replaceFirst(RegExp(r'^.*test/fixtures/'), '').replaceFirst(RegExp(r'\.jsonl$'), ''),
      'device': device,
      'adbd': adbd,
      'recorded': DateTime.now().toIso8601String().substring(0, 10),
      'note': note,
      'starts': online ? 'online' : 'connection',
      if (online) 'host_features': AdbConnectOptions.defaultHostFeatures.map((f) => f.name).join(','),
    }),
    for (final packet in packets)
      jsonEncode({
        'dir': packet.outgoing ? '>' : '<',
        'cmd': packet.command,
        'arg0': packet.arg0,
        'arg1': packet.arg1,
        'data': hex(packet.payload),
        'raw': hex(packet.raw),
      }),
  ];
  File(out)
    ..createSync(recursive: true)
    ..writeAsStringSync('${lines.join('\n')}\n');
  stdout.writeln('wrote $out: ${packets.length} packets');
}
