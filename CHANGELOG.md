# Changelog

## Unreleased

- Deadlines and output limits where a device that stayed connected but never finished could hang a call: `debug.screencap` (`timeout`, `maxBytes`), the `daemon` services (`timeout`), and `reverse` commands (30 s). The stream is closed and the connection stays usable.
- `AdbServer`: closing a device connection while its device tracking was still connecting to a server that had gone away raised an unhandled error.

## 1.0.1 (2026-11-18)

- Streams: a write from the device is acknowledged only once the listener has received it. Data the device sent together with its answer to `OPEN` (common for command output) was acknowledged as soon as someone listened, so a listener that paused at once could not hold the device back.
- Windows: a refused connection (`ERROR_CONNECTION_REFUSED`, 1225) is an `AdbRefusedException`, not an `AdbUnreachableException`.
- Repository: CI on Linux, macOS and Windows; `SECURITY.md`.

## 1.0.0 (2026-11-18)

First release: an ADB client in pure Dart for `adbd` over the network.

- **Connections**: classic network debugging with RSA keys (`AdbKeyPair`, `AdbPublicKey`, `adbkey` files compatible with desktop `adb`) and the approval prompt; wireless debugging with TLS connections and pairing by code or QR code (`AdbPairing`, `AdbPairingQr`; SPAKE2 as BoringSSL does it); `AdbConnection.connectTransport` for transports of your own (`AdbTransport`); `AdbServer` for devices behind a running adb server; `AdbConnection.waitFor` for devices coming back; cancellation, deadlines, liveness checks for devices that went away, ADB flow control with delayed acknowledgements, tracing.
- **Probes and discovery**: `AdbProbe` (`identify`, `knowsKey`, `scan`) never shows anything on a device; `AdbMdnsBrowser` and the `AdbServiceBrowser` interface for platform browsers.
- **Shell**: `AdbShell.run` (separate output, exit status, deadline, output limit), `exec`, interactive sessions with a terminal; `AdbProperties` (`getprop`, `setprop`, serial number, API level).
- **Files**: `AdbSync` (stat, list, read, write; sync v1 and v2; progress and stall guards) and `AdbSyncFiles` for files and folders on `dart:io`; compression with `AdbCompression` (LZ4 built in, Brotli and Zstandard pluggable).
- **Apps**: `AdbPackages`: streamed installs with progress, split APKs, several apps atomically, APEX modules, incremental installs (`installIncremental`), uninstall, and `list`, `paths`, `setEnabled`, `clearData`, `grantPermission`, `revokePermission`.
- **Networking and device services**: `forward`, `AdbReverse`, any service through `AdbConnection.open`; `AdbDaemon` (root, unroot, remount, reboot, tcpip, usb, verity); `AdbDebug` (JDWP, process tracking, logcat, screenshots, bug reports); `AdbRecovery.sideload`; `AdbBackup`.
- **Errors**: one sealed `AdbException` hierarchy with stable `AdbErrorCode`s.
- **Old devices**: Android 4.4 and later, with the fallbacks `adb` uses (no shell protocol, no `exec:`, push installs, Android 7-9's directory creation).
