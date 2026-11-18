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

```
> CNXN(0x01000001, maxdata, "host::features=…")
< AUTH(TOKEN, 0, <20 random bytes>)
> AUTH(SIGNATURE, 0, <256 bytes>)          one per key, until one is accepted
< AUTH(TOKEN, 0, <new token>)              the key was not accepted
> AUTH(RSAPUBLICKEY, 0, "<adb public key> <comment>\0")
  the device shows "Allow debugging?" and stays silent until its user answers
< CNXN(0x01000001, maxdata, "device::…")
```

Keys are RSA 2048 with exponent 65537. The signature is PKCS#1 v1.5 with the SHA-1 `DigestInfo`, the token standing in for the digest: it is not hashed again. The public key goes as `base64(<524-byte structure>) <comment>` with a trailing NUL; the structure holds the modulus size in words (64), −n⁻¹ mod 2³², the modulus and R² mod n (both little-endian), and the exponent. The dialog shows the MD5 fingerprint of that structure, which `AdbPublicKey.md5Fingerprint` gives.

"Cancel" sends nothing back, so a refusal looks like a user who has not answered; only `approvalTimeout` ends the wait. A device without authentication answers the first `CNXN` with its own. The probe (`AdbProbe.knowsKey`) stops after the signatures, before the public key, so it never shows the dialog.

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

`shell,v2,raw:<command>` runs a command with shell protocol v2, `shell,v2,pty:` an interactive shell with a terminal. Inside the stream's data, v2 frames packets as `{u8 id, u32 length little-endian, data}`, split across and packed into `WRTE`s freely:

| Id | Direction | Meaning |
| --- | --- | --- |
| 0 | to the device | stdin |
| 1, 2 | from the device | stdout, stderr |
| 3 | from the device | exit status, one byte |
| 4 | to the device | close stdin (end of input for a command without a PTY) |
| 5 | to the device | window size, `"<rows>x<cols>,<xpixels>x<ypixels>"` |

Without `shell_v2` (Android 6 and older) `shell:<command>` gives one stream with stdout and stderr merged and no exit status; `exec:<command>` (Android 5 and later) gives the command's bytes exactly, with no PTY and no framing. Commands travel in the `OPEN` payload, so they are bounded by the payload limit, and may not contain a NUL (adbd would end the name there).

## Sync

`OPEN("sync:")`, then requests `{u32 id, u32 length}` plus a path (UTF-8, up to 1024 bytes), all little-endian:

| Request | Answer |
| --- | --- |
| `STAT`, or `STA2`/`LST2` with `stat_v2` | mode, size, times (v1: 32-bit, zeros for a missing path; v2: 64-bit sizes, owner, an errno) |
| `LIST`, or `LIS2` with `ls_v2` | `DENT`/`DNT2` entries, then `DONE` padded to an entry's size |
| `RECV`, or `RCV2` with `sendrecv_v2` | `DATA` chunks of up to 64 KiB, then `DONE`; or `FAIL` with a message |
| `SEND` (`"<path>,<mode>"`), or `SND2` with `sendrecv_v2` | after the client's `DATA` chunks and `DONE {mtime}`: `OKAY` or `FAIL` |
| `QUIT` | ends the session |

`RCV2` and `SND2` carry flags: 1 Brotli, 2 LZ4, 4 Zstandard (compressed `DATA` chunks are pieces of one stream, not separate frames). After a `FAIL`, adbd closes the sync stream; the package opens a new session for the next request. A push that fails on the device (no space, read-only) is answered with `FAIL` at once while adbd keeps reading until `DONE`: the package stops sending as soon as anything comes back.

## Install

`abb_exec:package\0install\0-S\0<size>…` (Android 11+, arguments separated by NULs, no shell) or `exec:cmd package install -S <size> …` (Android 7+), then the APK's bytes on the same stream, then the package manager's answer (`Success` or `Failure [CODE: message]`) on it. Older devices get the APK pushed to `/data/local/tmp` and installed with `pm install`. Several APKs go through a session: `install-create`, one `install-write -S <size> <session> <name> -` per APK, `install-commit` (or `install-abandon`). The exit status of `pm` is never trusted: it often exits 0 after refusing.

Incremental installs (`install-incremental`) pass each file's v4 signature as an argument, then the client serves blocks: the device asks with `INCR` requests mixed into the package manager's output (prefetch a file, a missing block, serving complete), and the client answers with chunks of 4 KiB blocks, each with a small header, data blocks LZ4-compressed where that helps, preceded by the hash tree blocks that verify them.

## Half-open connections

A device that loses power or network leaves a socket that neither fails nor answers. Two checks notice it:

- every `OPEN` and every write must be acknowledged within `acknowledgementTimeout` (20 s by default);
- a connection whose streams only wait (a log being followed, a command that prints nothing) asks the device after `livenessInterval` (10 s) of silence: it opens a service that does not exist, which adbd refuses at once (`CLSE`) without logging anything.

Either check failing ends the connection with `AdbTimeoutException`, and every open stream and pending call fails with it.
