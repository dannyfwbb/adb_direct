# Changelog

## Unreleased

- Repository, license and documentation structure.
- Protocol layer: message codec and reader, `CNXN` banner and features, the `AdbException` hierarchy, the `AdbClock` seam.
- Test support: fixtures recorded from a real adbd and a scripted fake adbd.
- Keys: `AdbKeyPair` (generate, PEM in PKCS#8 and PKCS#1, adb-compatible), `AdbPublicKey` (adb's format, MD5 fingerprint); internally the AUTH token signature, the TLS certificate, HKDF and the TLS 1.3 exporter.
