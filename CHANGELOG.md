# Changelog

## Unreleased

- Repository, license and documentation structure.
- Protocol layer: message codec and reader, `CNXN` banner and features, the `AdbException` hierarchy, the `AdbClock` seam.
- Test support: fixtures recorded from a real adbd and a scripted fake adbd.
- Keys: `AdbKeyPair` (generate, PEM in PKCS#8 and PKCS#1, adb-compatible), `AdbPublicKey` (adb's format, MD5 fingerprint); internally the AUTH token signature, the TLS certificate, HKDF and the TLS 1.3 exporter.
- Connections: `AdbConnection` over TCP with the full handshake (several keys, the approval prompt or none, devices without authentication), streams with ADB flow control and delayed acknowledgements, acknowledgement deadlines and a liveness check that notice a device that went away, total teardown; `AdbProbe` (`identify`, `knowsKey`) that never prompts; `AdbShell` (`run` with separate output, exit status, timeout and output limit, a fallback for old devices, `exec`, interactive sessions); tracing; `tool/record_fixture.dart`.
- Files: `AdbSync` (`stat`, `list`, `read`, `write`, sync v1 and v2, reusable sessions, a fresh session after a device refusal, a stall guard per transfer) and `AdbSyncFiles` for `dart:io` (`pullFile`, `pushFile`, `pullDirectory`, `pushDirectory` with `onlyChanged`).
- Apps: `AdbPackages` (`install` streamed through `abb_exec` or `cmd`, or pushed on old devices; `installMultiple` in one session, abandoned on failure; `installMultiPackage`; `uninstall`), `AdbApk`, `AdbInstallOptions`, typed `AdbInstallException` codes, acknowledged-byte progress, a stall guard and a verification deadline. `AdbStream.flush`, `AdbStream.acknowledgedBytes` and `AdbStream.acknowledgements`; `AdbConnectOptions.packageManagerTimeout`. `tool/build_test_apks.sh` builds the test APKs.
- Wireless debugging: TLS connections (`STLS`, TLS 1.3 with the key's certificate, one session per key, `isTls`, `deviceCertificate`); `AdbPairing.pair` with a code and `AdbPairingQr` for QR codes (SPAKE2 over edwards25519 as BoringSSL does it, the TLS exporter, AES-128-GCM); `AdbPairingException.reason`. `tool/pair.dart`.
- Forwarding and device services: `AdbConnection.forward` (`AdbForward`), `AdbReverse` (`toLocalPort`, `add` with a handler, `list`, `remove`, `removeAll`; device `OPEN`s accepted only for our targets), `AdbDaemon` (`root`, `unroot`, `tcpip`, `usb`, `reboot`, `remount`, verity) with `AdbDaemonAnswer`, `AdbConnection.waitFor`, `AdbDebug` (`jdwp`, `trackJdwp`, `trackApps` with `AdbAppProcess`, `logcat`, `screencap`, `bugreport`), `AdbBackup`, `AdbRecovery.sideload`.
- `AdbConnection.connect(cancelOn:)` stops an attempt (TCP connect or a pending approval); `AdbConnection.close(drain: false)` closes without waiting on the device.
