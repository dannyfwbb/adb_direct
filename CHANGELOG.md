# Changelog

## Unreleased

- Repository, license and documentation structure.
- Protocol layer: message codec and reader, `CNXN` banner and features, the `AdbException` hierarchy, the `AdbClock` seam.
- Test support: fixtures recorded from a real adbd and a scripted fake adbd.
- Keys: `AdbKeyPair` (generate, PEM in PKCS#8 and PKCS#1, adb-compatible), `AdbPublicKey` (adb's format, MD5 fingerprint); internally the AUTH token signature, the TLS certificate, HKDF and the TLS 1.3 exporter.
- Connections: `AdbConnection` over TCP with the full handshake (several keys, the approval prompt or none, devices without authentication), streams with ADB flow control and delayed acknowledgements, acknowledgement deadlines and a liveness check that notice a device that went away, total teardown; `AdbProbe` (`identify`, `knowsKey`) that never prompts; `AdbShell` (`run` with separate output, exit status, timeout and output limit, a fallback for old devices, `exec`, interactive sessions); tracing; `tool/record_fixture.dart`.
- Files: `AdbSync` (`stat`, `list`, `read`, `write`, sync v1 and v2, reusable sessions, a fresh session after a device refusal, a stall guard per transfer) and `AdbSyncFiles` for `dart:io` (`pullFile`, `pushFile`, `pullDirectory`, `pushDirectory` with `onlyChanged`).
