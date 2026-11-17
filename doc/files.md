# Files

`adb.sync` speaks the sync protocol, the one behind `adb push`, `adb pull` and `adb ls`.

```dart
final info = await adb.sync.stat('/sdcard/Movies/clip.mp4');   // null if missing
final entries = await adb.sync.list('/sdcard/Download');
final bytes = await adb.sync.readAll('/sdcard/notes.txt');
await adb.sync.writeAll('/sdcard/notes.txt', utf8.encode('hello'));

// Streams, with progress, for big files:
await for (final chunk in adb.sync.read('/sdcard/big.bin', onProgress: print)) { … }
await adb.sync.write('/sdcard/big.bin', File('big.bin').openRead(), size: length);

// Files and directories on dart:io:
await adb.sync.pullFile('/sdcard/clip.mp4', File('clip.mp4'));
await adb.sync.pushDirectory(Directory('assets'), '/sdcard/assets', onlyChanged: true);
```

## What to expect

- `stat` describes links themselves by default (`lstat`); `followLinks: true` describes their target. `stat` returns null for a missing path and throws `AdbSyncException` for others it cannot see (permission denied: the message names the errno).
- `list` leaves out `.` and `..`, and entries the device can name but not describe. A directory it cannot read, or a path that is not a directory, gives an empty list on every version: `stat` tells them apart.
- `write` replaces the file. `permissions` default to `0644`, but adbd copies the owner's bits to group and others, as `adb push` does: the file ends up `0666`. `modified` sets its modification time (now by default; 1970 to 2106). Progress counts bytes the device has acknowledged. `writeLink` creates a symbolic link.
- A refusal (no permission, read-only file system, no space) is an `AdbSyncException` with the device's message, raised as soon as the device refuses, not after the whole file was sent. The connection stays usable; the next call starts a fresh sync session. A source stream that fails makes the write fail too, and adbd removes the partial file.
- A transfer that makes no progress for `AdbConnectOptions.transferStallTimeout` (30 s) fails with `AdbTimeoutException`: no byte arriving on a read, nothing acknowledged on a write (a slow device disk still acknowledges, so it is not a stall). The connection stays usable. A device that went away is noticed by the connection itself (see [connection.md](connection.md)).
- Calls in a row share one sync session; several at once open several. An idle session closes after two seconds.
- `pullFile` writes to a temporary file and renames it at the end, so a failed transfer leaves nothing behind; it keeps the device file's modification time. `pushDirectory` creates links as links instead of following them; `onlyChanged: true` skips files whose device copy has the same size and modification time, like `adb sync`. On devices without `stat_v2` the helpers describe links themselves.

## Devices and versions

| Device | Stat | Listing | Transfers |
| --- | --- | --- | --- |
| Android 9+ (or adbd with `stat_v2`, `ls_v2`, `sendrecv_v2`) | 64-bit sizes, owner, times, errno | full stat per entry | `SND2`/`RCV2` |
| Older | sizes modulo 4 GiB; missing and unreadable look the same; no `followLinks` | mode, size, time | `SEND`/`RECV` |

Compression (`adb push -z`) is not used: measured, it does not pay on a local network for the files that matter most (APKs are already compressed). It may come as an option later.

Measured on an Android 14 emulator over a forwarded port: write 360-485 MiB/s, read 310-320 MiB/s.
