// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A pure Dart ADB client that talks to adbd over the network.
///
/// Start with [AdbKeyPair] (the identity a device trusts) and
/// [AdbConnection.connect]; [AdbProbe] answers questions about a device
/// without making it ask its user anything.
library;

import 'src/connection/connection.dart';
import 'src/crypto/adb_key_pair.dart';
import 'src/probe/probe.dart';

export 'src/clock.dart' show AdbClock;
export 'src/connection/connection.dart' show AdbConnection;
export 'src/connection/options.dart' show AdbConnectOptions;
export 'src/crypto/adb_key_pair.dart' show AdbKeyPair;
export 'src/crypto/adb_public_key.dart' show AdbPublicKey;
export 'src/errors.dart';
export 'src/probe/probe.dart' show AdbEndpoint, AdbEndpointKind, AdbProbe;
export 'src/protocol/banner.dart' show AdbBanner, AdbDeviceState, AdbFeature;
export 'src/protocol/sync_protocol.dart' show AdbDirectoryEntry, AdbFileStat;
export 'src/services/packages.dart' show AdbApk, AdbInstallOptions, AdbPackages;
export 'src/services/shell.dart'
    show AdbShell, AdbShellResult, AdbShellSession, shellQuote;
export 'src/services/sync.dart' show AdbProgress, AdbSync;
export 'src/services/sync_files.dart' show AdbSyncFiles;
export 'src/stream/adb_stream.dart' show AdbStream;
export 'src/trace.dart'
    show AdbNoteTrace, AdbPacketTrace, AdbTraceEvent, AdbTracer;
