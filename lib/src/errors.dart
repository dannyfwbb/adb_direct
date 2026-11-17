// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

/// Stable identifiers for every way an ADB operation can fail.
///
/// The names never change meaning. Codes are added only together with a new
/// [AdbException] subclass, in a major version, so an exhaustive `switch`
/// stays exhaustive within a major version.
enum AdbErrorCode {
  /// No connection could be opened in time, or the network is unreachable.
  unreachable,

  /// The device answered and refused the connection.
  refused,

  /// The device has not accepted the key, or the user denied it.
  unauthorized,

  /// Pairing ended without a trusted key.
  pairingFailed,

  /// The connection is open but no answer came in time.
  timeout,

  /// The connection or the stream was closed by the other side.
  closed,

  /// The device sent something that breaks the protocol.
  protocol,

  /// The device refused to open the requested service.
  serviceUnavailable,

  /// The package manager refused the package.
  installFailed,

  /// A file operation failed on the device.
  syncFailed,

  /// The device does not support what was asked.
  notSupported,

  /// The caller cancelled the operation.
  cancelled,
}

/// The single exception type of this library.
///
/// Every failure is one of the subclasses, so a `switch` over an
/// [AdbException] is exhaustive. Subclasses are added only in major
/// versions. [code] gives the same information as a
/// stable value for logs and analytics, and [cause] keeps the underlying
/// error (an `OSError`, a `TlsException`, …) when there is one.
sealed class AdbException implements Exception {
  const AdbException(this.message, {this.cause});

  /// What went wrong, in words meant for developers.
  final String message;

  /// The error that led to this one, if any.
  final Object? cause;

  /// The stable identifier of this failure.
  AdbErrorCode get code;

  @override
  String toString() {
    final buffer = StringBuffer('AdbException(${code.name}): $message');
    if (cause != null) buffer.write(' (cause: $cause)');
    return buffer.toString();
  }
}

/// No connection could be opened in time, or the network is unreachable.
final class AdbUnreachableException extends AdbException {
  /// Creates the exception.
  const AdbUnreachableException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.unreachable;
}

/// The device answered and refused the connection.
final class AdbRefusedException extends AdbException {
  /// Creates the exception.
  const AdbRefusedException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.refused;
}

/// The device has not accepted the key, or the user denied it.
final class AdbUnauthorizedException extends AdbException {
  /// Creates the exception.
  const AdbUnauthorizedException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.unauthorized;
}

/// Pairing ended without a trusted key.
final class AdbPairingException extends AdbException {
  /// Creates the exception.
  const AdbPairingException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.pairingFailed;
}

/// The connection is open but no answer came in time.
///
/// A timeout while opening the socket is an [AdbUnreachableException]
/// instead; this one means silence after the socket was open, which is what
/// a device waiting for its user, or one that disappeared, looks like.
final class AdbTimeoutException extends AdbException {
  /// Creates the exception.
  const AdbTimeoutException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.timeout;
}

/// The connection or the stream was closed by the other side.
final class AdbClosedException extends AdbException {
  /// Creates the exception.
  const AdbClosedException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.closed;
}

/// The device sent something that breaks the protocol.
///
/// The connection is unusable afterwards: both sides share state that can no
/// longer be trusted.
final class AdbProtocolException extends AdbException {
  /// Creates the exception.
  const AdbProtocolException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.protocol;
}

/// The device refused to open [service].
final class AdbServiceUnavailableException extends AdbException {
  /// Creates the exception.
  const AdbServiceUnavailableException(
    super.message, {
    required this.service,
    super.cause,
  });

  /// The service name that was refused, as sent in `OPEN`.
  final String service;

  @override
  AdbErrorCode get code => AdbErrorCode.serviceUnavailable;
}

/// The package manager refused the package.
final class AdbInstallException extends AdbException {
  /// Creates the exception.
  const AdbInstallException(
    super.message, {
    required this.output,
    this.failureCode,
    super.cause,
  });

  /// The package manager's code, such as `INSTALL_FAILED_VERSION_DOWNGRADE`,
  /// when its answer contained one.
  final String? failureCode;

  /// The package manager's answer, exactly as the device sent it.
  final String output;

  @override
  AdbErrorCode get code => AdbErrorCode.installFailed;
}

/// A file operation failed on the device.
final class AdbSyncException extends AdbException {
  /// Creates the exception.
  const AdbSyncException(super.message, {required this.path, super.cause});

  /// The device path the failed operation was about.
  final String path;

  @override
  AdbErrorCode get code => AdbErrorCode.syncFailed;
}

/// The device does not support what was asked.
final class AdbNotSupportedException extends AdbException {
  /// Creates the exception.
  const AdbNotSupportedException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.notSupported;
}

/// The caller cancelled the operation.
final class AdbCancelledException extends AdbException {
  /// Creates the exception.
  const AdbCancelledException(super.message, {super.cause});

  @override
  AdbErrorCode get code => AdbErrorCode.cancelled;
}
