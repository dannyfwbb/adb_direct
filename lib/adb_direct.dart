// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A pure Dart ADB client that talks to adbd over the network.
///
/// Start with [AdbKeyPair] (the identity a device trusts) and [AdbConnection.connect]; [AdbProbe] answers questions
/// about a device without making it ask its user anything.
library;

import 'src/connection/connection.dart';
import 'src/crypto/adb_key_pair.dart';
import 'src/probe/probe.dart';

export 'src/clock.dart' show AdbClock;
export 'src/connection/connection.dart' show AdbConnection;
export 'src/connection/options.dart' show AdbConnectOptions;
export 'src/crypto/adb_key_pair.dart' show AdbKeyPair;
export 'src/crypto/adb_public_key.dart' show AdbPublicKey;
export 'src/discovery/adb_service.dart'
    show
        AdbService,
        AdbServiceBrowser,
        AdbServiceBrowserPairing,
        AdbServiceEvent,
        AdbServiceFound,
        AdbServiceLost,
        AdbServiceType,
        AdbServiceUpdated;
export 'src/discovery/mdns_browser.dart' show AdbMdnsBrowser;
export 'src/errors.dart';
export 'src/pairing/pairing.dart' show AdbPairedDevice, AdbPairing;
export 'src/pairing/pairing_qr.dart' show AdbPairingQr, AdbPairingService;
export 'src/probe/probe.dart' show AdbEndpoint, AdbEndpointKind, AdbProbe, AdbScanResult;
export 'src/protocol/banner.dart' show AdbBanner, AdbDeviceState, AdbFeature;
export 'src/protocol/sync_protocol.dart' show AdbDirectoryEntry, AdbFileStat;
export 'src/server/adb_server.dart' show AdbServer, AdbServerDevice;
export 'src/services/backup.dart' show AdbBackup;
export 'src/services/daemon.dart' show AdbDaemon, AdbDaemonAnswer, AdbDaemonOutcome;
export 'src/services/debug.dart' show AdbAppProcess, AdbBugReportProgress, AdbDebug;
export 'src/services/forward.dart' show AdbForward;
export 'src/services/packages.dart' show AdbApk, AdbInstallOptions, AdbPackageInfo, AdbPackages;
export 'src/services/properties.dart' show AdbProperties;
export 'src/services/recovery.dart' show AdbRecovery;
export 'src/services/reverse.dart' show AdbReverse, AdbReverseEntry, AdbReverseForward, AdbReverseHandler;
export 'src/services/shell.dart' show AdbShell, AdbShellResult, AdbShellSession, shellQuote;
export 'src/services/sync.dart' show AdbProgress, AdbSync;
export 'src/services/sync_files.dart' show AdbSyncFiles;
export 'src/stream/adb_stream.dart' show AdbStream;
export 'src/trace.dart' show AdbNoteTrace, AdbPacketTrace, AdbTraceEvent, AdbTracer;
export 'src/transport/transport.dart' show AdbTransport, AdbTransportListener;
