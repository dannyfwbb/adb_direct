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

Wireless debugging (Android 11+) listens on a port of its own (announced as `_adb-tls-connect._tcp`). The exchange starts in plain text and switches on the same socket:

```
> CNXN(0x01000001, maxdata, "host::features=…")    plain
< STLS(0x01000000, 0)                              plain, no AUTH
> STLS(0x01000000, 0)                              plain
  TLS 1.3; the server requires a client certificate
< CNXN(0x01000001, maxdata, "device::…")           inside TLS
```

The client certificate is the authentication: its public key must be one the device trusts (paired, or allowed earlier on a classic connection: both land in `adb_keys`). In TLS 1.3 a server that refuses the client's certificate does so after the client considers the handshake done, so a refused key shows up as the session closing before `CNXN` (adbd's verify callback rejects untrusted keys; observed with a test server, not yet on a device that checks keys). A dropped network looks the same, so the error keeps the underlying close as its cause. One TLS session presents one key, so with several keys the package opens one connection per key until one is accepted. Neither side can verify the other's certificate against anything: the device's certificate is self-signed (`C=US, O=Android, CN=Adb`), and the package's has the same shape (X.509 v3, the same names and extensions, ten years, SHA-256 with RSA).

## Pairing

Pairing puts a key into `adb_keys` with the code the device shows, on a separate port (`_adb-tls-pairing._tcp`), with no ADB messages:

1. TLS 1.3; both sides present certificates and neither checks the other's.
2. Both sides export 64 bytes of keying material (label `adb-label` plus its NUL, no context) and append them to the code: the password is bound to this TLS session.
3. SPAKE2 over edwards25519 as BoringSSL implements it (names `adb pair client\0` and `adb pair server\0`): each side sends 32 bytes and derives a 64-byte key.
4. HKDF-SHA256 turns it into an AES-128-GCM key (info `adb pairing_auth aes-128-gcm key`); nonces are a little-endian 64-bit counter per direction, then four zero bytes. Both directions share the key and start at 0, so the two first messages use the same key and nonce: AOSP's design, kept for compatibility, and reachable only inside the TLS session.
5. Each side sends its `PeerInfo` (8192 bytes: a type byte, then zero-padded data), encrypted: the client its public key in adb's text form, the device its GUID.

Packets on the pairing port are `{u8 version = 1, u8 type, u32 size big-endian}` and a payload of 1 to 16384 bytes (type 0 the SPAKE2 message, type 1 the peer info). A wrong code makes the two keys differ, so the device's answer does not decrypt. On Android the pairing server runs in `system_server`, not in adbd, and it answers even a wrong code; the dialog stays open, and a second attempt with the right code pairs (both seen on an Android 17 emulator).

## Shell

Not implemented yet.

## Sync

Not implemented yet.

## Install

Not implemented yet.

## Half-open connections

Not implemented yet.
