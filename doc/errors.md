# Errors

Every failure is an `AdbException` (a sealed type) with a stable `code` and, when there is one, the underlying `cause`. Codes do not change between minor versions; new codes may be added.

| Code | When |
| --- | --- |
| `unreachable` | The socket could not be opened in time, or the network is unreachable |
| `refused` | The device answered and refused the connection |
| `unauthorized` | The device has not accepted the key (yet) |
| `pairing_failed` | Pairing ended without a trusted key: a wrong code, an expired pairing session, or a failed handshake |
| `timeout` | The socket is open but no answer came in time: a command past its deadline, a transfer that stalled |
| `closed` | The connection or the stream was closed by the other side |
| `install_failed` | The package manager refused the APK; its answer is kept in the message |
| `protocol` | The device sent something the package does not understand |

A timeout while opening the socket is `unreachable`; `timeout` is reserved for silence after the socket is open, which is what a device waiting for its user's approval, or one that disappeared, looks like.

Not implemented yet.
