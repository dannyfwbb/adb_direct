// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

import '../protocol/banner.dart';

/// How a connection is opened and kept alive.
@immutable
final class AdbConnectOptions {
  /// Creates options; every value has a default suited to devices on a
  /// local network.
  const AdbConnectOptions({
    this.connectTimeout = const Duration(seconds: 10),
    this.handshakeTimeout = const Duration(seconds: 10),
    this.approvalTimeout = const Duration(minutes: 2),
    this.allowPrompt = true,
    this.acknowledgementTimeout = const Duration(seconds: 20),
    this.livenessInterval = const Duration(seconds: 10),
    this.transferStallTimeout = const Duration(seconds: 30),
    this.packageManagerTimeout = const Duration(minutes: 5),
    this.receiveWindow = 4 * 1024 * 1024,
    this.hostFeatures = defaultHostFeatures,
  });

  /// The features this library implements and announces by default.
  ///
  /// A feature takes effect only when both sides list it, so only
  /// implemented ones are announced; the set grows with the library.
  static const Set<AdbFeature> defaultHostFeatures = {
    AdbFeature.shellV2,
    AdbFeature.cmd,
    AdbFeature.abbExec,
    AdbFeature.statV2,
    AdbFeature.lsV2,
    AdbFeature.sendRecvV2,
    AdbFeature.fixedPushMkdir,
    AdbFeature.delayedAck,
  };

  /// Time allowed to open the TCP connection. Exceeding it means
  /// "unreachable".
  final Duration connectTimeout;

  /// Time allowed for each step of the handshake before the device asks
  /// its user (and for the device to answer at all).
  final Duration handshakeTimeout;

  /// Time allowed for the user to accept the key on the device after it is
  /// offered.
  final Duration approvalTimeout;

  /// Whether the public key may be offered when the device does not trust
  /// any of the keys, which shows "Allow debugging?" on the device. When
  /// false, an untrusted key fails with `AdbUnauthorizedException` and the
  /// device's user sees nothing.
  final bool allowPrompt;

  /// The longest a healthy device takes to acknowledge an `OPEN` or a write.
  /// When an acknowledgement is overdue the device is taken as gone (frozen,
  /// switched off, or the network dropped) and the connection fails with
  /// `AdbTimeoutException`. Without this, a half-open socket would hang
  /// forever.
  final Duration acknowledgementTimeout;

  /// How long streams may wait in silence before the connection checks that
  /// the device is still there.
  ///
  /// A stream that only reads (a download, a quiet command) sends nothing
  /// the device must acknowledge, so a frozen device would go unnoticed.
  /// After this much silence while streams are open, the connection opens a
  /// service that does not exist: adbd refuses it at once (well under a
  /// millisecond, nothing logged), and a missing answer within
  /// [acknowledgementTimeout] fails the connection. Null turns the check
  /// off. No probe is sent while no stream is open.
  final Duration? livenessInterval;

  /// How long a file transfer may make no progress (no byte arriving, no
  /// write acknowledged) before it fails with `AdbTimeoutException`. The
  /// connection stays up: a slow transfer is not a dead device.
  final Duration transferStallTimeout;

  /// How long the package manager may take to answer a command. After an
  /// upload it verifies and optimizes the app in silence, which takes
  /// minutes for a big app on a slow TV.
  final Duration packageManagerTimeout;

  /// Bytes the device may send on a stream before we acknowledge, when
  /// delayed acknowledgements are in use. Bounds the memory a stream whose
  /// reader is slow can take.
  final int receiveWindow;

  /// The features announced in our `CNXN`.
  final Set<AdbFeature> hostFeatures;

  /// Throws [ArgumentError] when a value cannot work: a duration that is
  /// not positive, or a receive window outside 1 B..2 GiB (adbd refuses an
  /// `OPEN` with a window of 0, and acknowledgements are 32-bit).
  void validate() {
    void positive(Duration value, String name) {
      if (value <= Duration.zero) {
        throw ArgumentError.value(value, name, 'must be positive');
      }
    }

    positive(connectTimeout, 'connectTimeout');
    positive(handshakeTimeout, 'handshakeTimeout');
    positive(approvalTimeout, 'approvalTimeout');
    positive(acknowledgementTimeout, 'acknowledgementTimeout');
    positive(transferStallTimeout, 'transferStallTimeout');
    positive(packageManagerTimeout, 'packageManagerTimeout');
    if (livenessInterval case final interval?) {
      positive(interval, 'livenessInterval');
    }
    if (receiveWindow < 1 || receiveWindow > 0x7fffffff) {
      throw ArgumentError.value(receiveWindow, 'receiveWindow', 'must be between 1 and 2147483647');
    }
  }
}
