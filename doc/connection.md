# Connecting

```dart
final keys = AdbKeyPair.fromPem(storedPem);           // see keys.md
final adb = await AdbConnection.connect(
  '192.168.0.20', 5555,
  key: keys,
  onWaitingForApproval: () => print('Accept the prompt on the device'),
);
print('${adb.device.model}, features: ${adb.device.features}');
final result = await adb.shell.run('getprop ro.build.version.release');
await adb.close();
```

## The handshake

1. The library sends `CNXN`; the device answers with an `AUTH` token.
2. It signs the token with `key`, then each of `extraKeys`. A device that trusts one of them answers with its own `CNXN`: connected.
3. If none is trusted and `AdbConnectOptions.allowPrompt` is true (the default), it offers `key`'s public key. The device shows "Allow debugging?" with the key's fingerprint (`key.publicKey.md5Fingerprint`), and `onWaitingForApproval` is called. The call then waits up to `approvalTimeout` (2 minutes) for the user.
   - "Allow" connects. "Always allow from this computer" also makes the device trust the key from then on.
   - "Cancel" sends nothing back: the device simply stays silent, so a refusal and a user who has not answered yet look the same. The call fails with `AdbUnauthorizedException` when `approvalTimeout` runs out.

To stop an attempt early (the user backed out, or the app wants another device), pass `cancelOn`: when that future completes before the connection is up, the TCP connect or the handshake stops at once, the socket closes, and `connect` throws `AdbCancelledException`. Once connected, `cancelOn` is ignored.
4. With `allowPrompt: false`, an untrusted key fails at once with `AdbUnauthorizedException`, and the device's user sees nothing.

A device without authentication (userdebug builds, some emulators) connects at step 1. A wireless-debugging port answers with `STLS` (TLS), which this version reports as `AdbNotSupportedException`.

## Probes

`AdbProbe` asks without ever offering a key, so no prompt appears on any screen: safe for looking around a network.

- `AdbProbe.identify(host, port)` sends one `CNXN` and reads one answer: `adbAuthentication`, `adbOpen` (with the banner), `adbTls` or `notAdb`.
- `AdbProbe.knowsKey(host, port, key)` signs the device's token and stops: true when the device trusts the key.

## Streams

`adb.open(service)` opens a stream to any device service (`shell:…`, `exec:…`, `sync:`, `tcp:8080`, …). Read `stream.input`; write with `stream.write`; `stream.flush()` completes when the device has acknowledged everything written; `stream.acknowledgedBytes` counts it. `stream.close()` ends both directions (ADB streams have no half-close). Many streams share one connection.

Flow control is ADB's own: the device is told it may send more only when your listener has received the data, so pausing the subscription slows the device down (whatever arrives while it is paused waits, unacknowledged, until it resumes); `write` completes when the data is on its way within the device's window. With delayed acknowledgements (devices that list `delayed_ack`, Android 14 and recent adbd updates), several writes are in flight at once.

## When the device goes away

A switched-off TV or a dropped Wi-Fi leaves a socket that never fails by itself. The connection checks the device when there is reason to doubt it:

- streams that wait in silence for `livenessInterval` (10 s);
- an `OPEN` or a write not acknowledged within `acknowledgementTimeout` (20 s). adbd holds acknowledgements back on purpose while a process does not read its input, so this alone proves nothing.

The check opens a service that does not exist, which adbd refuses at once (well under a millisecond, nothing logged on the device). An answer means the device is fine and the waiting stream is simply slow: enforce your own deadline there (`AdbShell.run` has one). No answer within `acknowledgementTimeout` means the device is gone: the connection fails with `AdbTimeoutException`, and so does every stream and pending call on it, so nothing is left waiting. `adb.done` completes and `adb.closeReason` says why. Measured on a frozen emulator: noticed after 28 s.

`close()` sends what is queued for at most `acknowledgementTimeout`, then drops the connection. `close(drain: false)` drops it at once: use it when the device may be gone, so closing does not wait on it.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `connectTimeout` | 10 s | Opening the TCP connection (`AdbUnreachableException` past it) |
| `handshakeTimeout` | 10 s | Each step of the handshake before the user is asked |
| `approvalTimeout` | 2 min | The user's answer to "Allow debugging?" |
| `allowPrompt` | true | Whether the key may be offered |
| `acknowledgementTimeout` | 20 s | Waiting this long for an acknowledgement triggers a check of the device; a check without an answer for this long fails the connection |
| `livenessInterval` | 10 s | Silence before checking the device is there; null turns it off |
| `packageManagerTimeout` | 5 min | How long the package manager may take to answer (it verifies apps in silence) |
| `transferStallTimeout` | 30 s | A file transfer with no progress for this long fails (see [files.md](files.md)) |
| `receiveWindow` | 4 MiB | How much a device may send ahead on one stream (delayed acknowledgements); 1 B to 2 GiB |
| `hostFeatures` | `shell_v2`, `cmd`, `abb_exec`, `stat_v2`, `ls_v2`, `sendrecv_v2`, `fixed_push_mkdir`, `delayed_ack` (what the library implements so far) | Features announced in `CNXN` |

## Tracing

Pass `tracer:` to see every message and state change (`AdbPacketTrace`, `AdbNoteTrace`), for logs or for recording test fixtures (`tool/record_fixture.dart`). Payloads include command output and public keys, never private keys.
