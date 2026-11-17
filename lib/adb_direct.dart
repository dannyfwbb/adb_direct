// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// A pure Dart ADB client that talks to adbd over the network.
///
/// The library is in development; this entry point grows phase by phase.
library;

export 'src/clock.dart' show AdbClock;
export 'src/errors.dart';
export 'src/protocol/banner.dart' show AdbBanner, AdbDeviceState, AdbFeature;
