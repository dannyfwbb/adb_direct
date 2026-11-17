# Errors

Every failure is an `AdbException`. It is a sealed class, so a `switch` over its subclasses is exhaustive; `code` gives the same information as a stable value for logs, and `cause` keeps the underlying error (an `OSError`, a TLS error, …) when there is one.

| Subclass | `code` | When |
| --- | --- | --- |
| `AdbUnreachableException` | `unreachable` | The socket could not be opened in time, or the network is unreachable |
| `AdbRefusedException` | `refused` | The device answered and refused the connection |
| `AdbUnauthorizedException` | `unauthorized` | The device has not accepted the key, or its user denied it |
| `AdbPairingException` | `pairingFailed` | Pairing ended without a trusted key: a wrong code, an expired pairing session, or a failed handshake |
| `AdbTimeoutException` | `timeout` | The socket is open but no answer came in time: a command past its deadline, a transfer that stalled |
| `AdbClosedException` | `closed` | The connection or the stream was closed by the other side |
| `AdbProtocolException` | `protocol` | The device sent something that breaks the protocol; the connection is unusable afterwards |
| `AdbServiceUnavailableException` | `serviceUnavailable` | The device refused to open a service (`service` names it) |
| `AdbInstallException` | `installFailed` | The package manager refused a package; `failureCode` (such as `INSTALL_FAILED_VERSION_DOWNGRADE`) and the exact `output` are kept |
| `AdbSyncException` | `syncFailed` | A file operation failed on the device (`path` names it) |
| `AdbNotSupportedException` | `notSupported` | The device does not support what was asked |
| `AdbCancelledException` | `cancelled` | The caller cancelled the operation |

A timeout while opening the socket is `unreachable`; `timeout` is reserved for silence after the socket is open, which is what a device waiting for its user's approval, or one that disappeared, looks like.

Codes keep their meaning across versions. A new failure kind arrives as a new subclass with a new code, and only in a major version, so an exhaustive `switch` over the subclasses or over `AdbErrorCode` stays exhaustive within a major version.
