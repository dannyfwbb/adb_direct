// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Protocol constants shared by both ends of an ADB connection.
///
/// Values match adbd's `adb.h`. They describe the wire format and never
/// depend on the device.
abstract final class AdbProtocol {
  /// The oldest protocol version: payload checksums are required.
  static const int versionMin = 0x01000000;

  /// The version from which payload checksums are sent as zero and ignored.
  static const int versionSkipChecksum = 0x01000001;

  /// The version this library announces.
  static const int version = versionSkipChecksum;

  /// The version carried in `STLS` messages.
  static const int stlsVersion = 0x01000000;

  /// The payload limit of old devices, and the limit for every message sent
  /// before the device's `CNXN` tells us its own limit.
  static const int maxPayloadV1 = 4 * 1024;

  /// The largest payload this library accepts or announces.
  static const int maxPayload = 1024 * 1024;

  /// Size of a message header in bytes.
  static const int headerLength = 24;

  /// Size of the random token in an `AUTH` challenge.
  static const int authTokenLength = 20;

  /// The receive window this library announces per stream when delayed
  /// acknowledgements are in use. adbd uses the same value.
  static const int delayedAckWindow = 32 * 1024 * 1024;
}
