# Scope

`adb_direct` aims to do everything a user of `adb` needs from a device, from pure Dart, with every device that speaks ADB: Android 4.4 to the newest, phones, TVs, emulators, watches and cars. This page lists every area and its state. Anything that cannot be done in pure Dart gets an interface so it can be plugged in.

States: **planned** (designed, not written), **in progress**, **built** (implemented and tested, not yet released), **done** (with the version that shipped it).

## Coverage

### Transports

| Area | `adb` equivalent | State |
| --- | --- | --- |
| TCP, classic network debugging | `adb connect host:5555` | built |
| TLS (Android 11+ wireless debugging) | `adb connect` to an `_adb-tls-connect` service | built |
| Pairing with a six-digit code | `adb pair host:port code` | built |
| Pairing by QR code | the QR flow in Android Studio | built, not yet checked on a device (the caller supplies mDNS results) |
| A transport interface for anything that moves bytes (USB through a platform plugin, a tunnel) | `adb -d` | planned |
| Client for a running adb server (port 5037) | `adb -H`, `-P` | planned |

### Authentication and keys

| Area | `adb` equivalent | State |
| --- | --- | --- |
| RSA key pair, ADB public key format | `adb keygen` | built |
| Signing the device's token, offering the public key | the "Allow debugging?" flow | built |
| Self-signed certificate for TLS and pairing | — | built |
| Reading and writing `adbkey` / `adbkey.pub` files | `~/.android/adbkey` | built |

### Discovery

| Area | `adb` equivalent | State |
| --- | --- | --- |
| mDNS service names, parsing announcements | — | planned |
| Built-in mDNS browsing on platforms where multicast works from `dart:io` | `adb mdns services` | planned |
| A hook for platform discovery (iOS `NWBrowser`) | — | planned |
| A probe that tells whether an address speaks ADB, without authenticating | — | built |
| A check whether a device already trusts a key, without asking its user | — | built |

### Device state

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Identity and features from the connection banner | `adb get-state`, `adb features` | built |
| Serial, properties | `adb get-serialno`, `getprop` | planned |
| Reboot to system, bootloader, recovery, sideload | `adb reboot …` | built |
| Restart adbd as root, back as user | `adb root`, `adb unroot` | built |
| Remount, verity | `adb remount`, `adb disable-verity` | built |
| Switch to TCP or USB mode | `adb tcpip`, `adb usb` | built |
| Wait for a device to come back | `adb wait-for-…` | built (`AdbConnection.waitFor`) |

### Shell

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Shell protocol v2: stdout, stderr, exit code | `adb shell cmd` | built |
| Fallback for devices without `shell_v2` | — | built |
| Interactive shell with a PTY, window size, stdin | `adb shell` | built |
| Raw exec without a PTY | `adb exec-out` | built |
| Streaming output (logcat and the like) | `adb logcat` | built |
| Deadlines per command, output limits | — | built |

### Files

| Area | `adb` equivalent | State |
| --- | --- | --- |
| stat, list, pull, push (sync v1) | `adb pull`, `adb push`, `adb ls` | built |
| Sync v2 (`stat_v2`, `ls_v2`, `sendrecv_v2`) | — | built |
| Compression in sync where pure Dart allows it | `adb push -z` | planned |
| Directories, timestamps, modes | `adb push -a`, `adb sync` | built |
| Progress and stall detection on every transfer | — | built |

### Apps

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Streamed install with progress | `adb install` | built |
| Split APKs in one session | `adb install-multiple` | built |
| Several packages atomically | `adb install-multi-package` | built |
| Install options (replace, downgrade, grant, test, user) | `adb install -r -d -g -t --user` | built |
| Uninstall, keep data | `adb uninstall [-k]` | built |
| Incremental install | `adb install --incremental` | planned |
| `cmd` and `abb_exec` where the device has them, `pm` otherwise | — | built |
| APEX modules | `adb install --apex` | planned |
| App management (list, enable, disable, clear data, permissions) as typed helpers over `pm` | `adb shell pm …` | planned |

### Networking

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Forward a local port to the device (`tcp:`, `localabstract:`, `localreserved:`, `localfilesystem:`, `jdwp:`) | `adb forward` | built (in-process; no `--list` of other processes' forwards) |
| Reverse forwarding, to a local port or to code | `adb reverse` | built |
| Opening any device service as a stream | — | built |

### Other services

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Bug report | `adb bugreport` | built |
| JDWP process list, a stream to a process's JDWP | `adb jdwp`, `track-jdwp` | built |
| App process tracking (pid, debuggable, profileable, architecture, packages) | `adb track-app` | built |
| Device files opened directly | `dev:`, `dev-raw:` services | through `open('dev:<path>')`; no helper, not checked on a device |
| Screenshots and log streaming helpers | `adb exec-out screencap -p`, `adb logcat` | built |
| Sideload an OTA in recovery | `adb sideload` | built, not yet checked on a device in recovery |
| Backup and restore (deprecated on the device side) | `adb backup`, `adb restore` | built, not yet checked on a device (needs on-screen confirmation) |

## Left to the caller

- **Which addresses to connect to.** The package connects where it is told; restricting connections (for example to private addresses) is the caller's policy.
- **Key storage.** The package reads and writes key bytes and `adbkey` files; where they live is the caller's choice.
- **Parsing what device commands print.** `pm`, `dumpsys` and `getprop` output belongs to the app, beyond the helpers listed above.
- **Background execution** on mobile platforms.

## Cannot be done in pure Dart

- **USB.** Needs libusb or a platform API. The transport interface lets a separate package provide it.
- **The web.** Browsers do not open raw TCP sockets.
