# Scope

`adb_direct` aims to do everything a user of `adb` needs from a device, from pure Dart, with every device that speaks ADB: Android 4.4 to the newest, phones, TVs, emulators, watches and cars. This page lists every area and its state. Anything that cannot be done in pure Dart gets an interface so it can be plugged in.

States: **planned** (designed, not written), **in progress**, **built** (implemented and tested, not yet released), **done** (with the version that shipped it).

## Coverage

### Transports

| Area | `adb` equivalent | State |
| --- | --- | --- |
| TCP, classic network debugging | `adb connect host:5555` | done (1.0.0) |
| TLS (Android 11+ wireless debugging) | `adb connect` to an `_adb-tls-connect` service | done (1.0.0) |
| Pairing with a six-digit code | `adb pair host:port code` | done (1.0.0) |
| Pairing by QR code | the QR flow in Android Studio | done (1.0.0), not yet checked on a device (the caller supplies mDNS results) |
| A transport interface for anything that moves bytes (USB through a platform plugin, a tunnel) | `adb -d` | done (1.0.0) (`AdbTransport`, `AdbConnection.connectTransport`; a USB outline in `example/`) |
| Client for a running adb server (port 5037): devices, track, connect, pair, and every service through it | `adb -H`, `-P` | done (1.0.0) (`AdbServer`) |

### Authentication and keys

| Area | `adb` equivalent | State |
| --- | --- | --- |
| RSA key pair, ADB public key format | `adb keygen` | done (1.0.0) |
| Signing the device's token, offering the public key | the "Allow debugging?" flow | done (1.0.0) |
| Self-signed certificate for TLS and pairing | — | done (1.0.0) |
| Reading and writing `adbkey` / `adbkey.pub` files | `~/.android/adbkey` | done (1.0.0) |

### Discovery

| Area | `adb` equivalent | State |
| --- | --- | --- |
| mDNS service names, parsing announcements | — | done (1.0.0) |
| Built-in mDNS browsing on platforms where multicast works from `dart:io` | `adb mdns services` | done (1.0.0), IPv6 (unreleased) (IPv4 checked against Avahi on Linux) |
| A hook for platform discovery (iOS `NWBrowser`, Android NSD) | — | done (1.0.0) (`AdbServiceBrowser`, example adapter) |
| A probe that tells whether an address speaks ADB, without authenticating | — | done (1.0.0) |
| A check whether a device already trusts a key, without asking its user | — | done (1.0.0) |
| Concurrent probing for scans (the scan policy stays with the app) | — | done (1.0.0) (`AdbProbe.scan`) |

### Device state

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Identity and features from the connection banner | `adb get-state`, `adb features` | done (1.0.0) |
| Serial, properties | `adb get-serialno`, `getprop`, `setprop` | done (1.0.0) (`AdbProperties`) |
| Reboot to system, bootloader, recovery, sideload | `adb reboot …` | done (1.0.0) |
| Restart adbd as root, back as user | `adb root`, `adb unroot` | done (1.0.0) |
| Remount, verity | `adb remount`, `adb disable-verity` | done (1.0.0) |
| Switch to TCP or USB mode | `adb tcpip`, `adb usb` | done (1.0.0) |
| Wait for a device to come back | `adb wait-for-…` | done (1.0.0) (`AdbConnection.waitFor`) |

### Shell

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Shell protocol v2: stdout, stderr, exit code | `adb shell cmd` | done (1.0.0) |
| Fallback for devices without `shell_v2` | — | done (1.0.0) |
| Interactive shell with a PTY, window size, stdin | `adb shell` | done (1.0.0) |
| Raw exec without a PTY | `adb exec-out` | done (1.0.0) |
| Streaming output (logcat and the like) | `adb logcat` | done (1.0.0) |
| Deadlines per command, output limits | — | done (1.0.0), extended to daemon services and `reverse` (1.1.0) |

### Files

| Area | `adb` equivalent | State |
| --- | --- | --- |
| stat, list, pull, push (sync v1) | `adb pull`, `adb push`, `adb ls` | done (1.0.0) |
| Sync v2 (`stat_v2`, `ls_v2`, `sendrecv_v2`) | — | done (1.0.0) |
| Compression in sync | `adb push -z`, `adb pull -z` | done (1.0.0): LZ4 built in (own codec); Brotli and Zstandard through pluggable converters (`AdbCompression`) |
| Directories, timestamps, modes | `adb push -a`, `adb sync` | done (1.0.0) |
| Progress and stall detection on every transfer | — | done (1.0.0) |

### Apps

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Streamed install with progress | `adb install` | done (1.0.0) |
| Split APKs in one session | `adb install-multiple` | done (1.0.0) |
| Several packages atomically | `adb install-multi-package` | done (1.0.0) |
| Install options (replace, downgrade, grant, test, user) | `adb install -r -d -g -t --user` | done (1.0.0) |
| Uninstall, keep data | `adb uninstall [-k]` | done (1.0.0) |
| Incremental install | `adb install --incremental` | done (1.0.0) (`installIncremental`; needs the APKs' v4 signatures) |
| `cmd` and `abb_exec` where the device has them, `pm` otherwise | — | done (1.0.0) |
| APEX modules | `adb install --apex` | done (1.0.0) (staging checked only up to the package manager's refusal of a non-module) |
| App management (list, paths, enable, disable, clear data, permissions) as typed helpers over `pm` | `adb shell pm …` | done (1.0.0) |

### Networking

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Forward a local port to the device (`tcp:`, `localabstract:`, `localreserved:`, `localfilesystem:`, `jdwp:`) | `adb forward` | done (1.0.0) (in-process; no `--list` of other processes' forwards) |
| Reverse forwarding, to a local port or to code | `adb reverse` | done (1.0.0) |
| Opening any device service as a stream | — | done (1.0.0) |

### Other services

| Area | `adb` equivalent | State |
| --- | --- | --- |
| Bug report | `adb bugreport` | done (1.0.0), stall guard (1.1.0) |
| JDWP process list, a stream to a process's JDWP | `adb jdwp`, `track-jdwp` | done (1.0.0) |
| App process tracking (pid, debuggable, profileable, architecture, packages) | `adb track-app` | done (1.0.0) |
| Device files opened directly | `dev:`, `dev-raw:` services | through `open('dev:<path>')`; no helper, not checked on a device |
| Screenshots and log streaming helpers | `adb exec-out screencap -p`, `adb logcat` | done (1.0.0), screenshot deadline and size limit (1.1.0) |
| Sideload an OTA in recovery | `adb sideload` | done (1.0.0), not yet checked on a device in recovery |
| Backup and restore (deprecated on the device side) | `adb backup`, `adb restore` | done (1.0.0), not yet checked on a device (needs on-screen confirmation) |

## Left to the caller

- **Which addresses to connect to.** The package connects where it is told; restricting connections (for example to private addresses) is the caller's policy.
- **Key storage.** The package reads and writes key bytes and `adbkey` files; where they live is the caller's choice.
- **Parsing what device commands print.** `pm`, `dumpsys` and `getprop` output belongs to the app, beyond the helpers listed above.
- **Background execution** on mobile platforms.

## Cannot be done in pure Dart

- **USB.** Needs libusb or a platform API. The transport interface lets a separate package provide it.
- **The web.** Browsers do not open raw TCP sockets.
