# Protocol notes

Notes on the parts of the ADB protocol the package implements, for readers of the code. The reference is AOSP's `packages/modules/adb` (`protocol.txt`, `SYNC.TXT`, `docs/dev/adb_wifi.md`). Each section says which version of the package implements it.

## Messages

Every message is a 24-byte header, six little-endian `uint32` values, followed by `data_length` bytes of payload:

| Field | Meaning |
| --- | --- |
| `command` | Four ASCII characters read as a little-endian integer |
| `arg0`, `arg1` | Depend on the command |
| `data_length` | Payload size |
| `data_check` | Sum of the payload bytes; ignored from protocol version `0x01000001` on |
| `magic` | `command ^ 0xffffffff` |

| Command | Use |
| --- | --- |
| `CNXN` | Opens the connection; carries the protocol version, the maximum payload and the system identity string |
| `AUTH` | RSA authentication: token, signature, public key |
| `STLS` | Switches the connection to TLS |
| `OPEN` | Opens a stream to a service (`shell:`, `sync:`, `exec:`) |
| `OKAY` | Acknowledges a stream or a write |
| `WRTE` | Data on a stream |
| `CLSE` | Closes a stream |

Not implemented yet.

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
