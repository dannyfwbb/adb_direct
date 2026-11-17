# Protocol notes

Notes on the parts of the ADB protocol the package implements, for readers of the code. The reference is AOSP's `packages/modules/adb` (`protocol.txt`, `SYNC.TXT`, `docs/dev/adb_wifi.md`). Each section says which version of the package implements it.

## Messages

Implemented in `lib/src/protocol/` (internal; the public API is built on it).

Every message is a 24-byte header, six little-endian `uint32` values, followed by `data_length` bytes of payload:

| Field | Meaning |
| --- | --- |
| `command` | Four ASCII characters read as a little-endian integer |
| `arg0`, `arg1` | Depend on the command. Stream ids are relative to the sender |
| `data_length` | Payload size, never above the peer's limit |
| `data_check` | The sum of the payload bytes, verified by nobody: adbd ignores it, and so does this library. It is computed while the negotiated version is `0x01000000`, which includes the messages sent before the device's `CNXN` arrives; once both sides speak `0x01000001` it is 0 |
| `magic` | `command ^ 0xffffffff`. A wrong magic, or a payload above the limit, means the stream can no longer be framed: the connection is closed |

| Command | Use |
| --- | --- |
| `CNXN` | Opens the connection; carries the protocol version, the payload limit and the identity banner |
| `AUTH` | RSA authentication: token (1), signature (2), public key (3) |
| `STLS` | Switches the connection to TLS |
| `OPEN` | Opens a stream to a service (`shell:`, `sync:`, `exec:`, …). The service name ends with NUL |
| `OKAY` | The stream is ready, or a write was consumed |
| `WRTE` | Data on a stream |
| `CLSE` | Closes a stream. `CLSE(0, id)` refuses an `OPEN` |

A message with an unknown command, or the obsolete `SYNC`, is skipped and the connection goes on, as adbd does: a newer device that adds a command keeps working.

Limits: a payload is at most 1 MiB, or the smaller limit the device announces. Messages sent before the device's `CNXN` stay within 4096 bytes, the limit of old devices.

### The banner

`CNXN` carries `<systemtype>:<serial>:<key>=<value>;…`. A device sends `device::ro.product.name=…;ro.product.model=…;ro.product.device=…;features=shell_v2,cmd,…`; the host sends `host::features=…`. The host banner is sent **without** a trailing NUL: adbd would read the NUL as part of the last feature's name and ignore that feature. Features are used only when both sides list them.

Parsing is more tolerant than adb's own: a `:` or `=` inside a value is kept (adb would cut or drop the entry), and trailing NULs or semicolons are ignored.

## Classic authentication

Not implemented yet.

## TLS connections

Not implemented yet.

## Pairing

Not implemented yet.

## Shell

Not implemented yet.

## Sync

Not implemented yet.

## Install

Not implemented yet.

## Half-open connections

Not implemented yet.
