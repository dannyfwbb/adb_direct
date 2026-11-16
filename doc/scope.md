# Scope

`adb_direct` covers the ADB protocol between a client and `adbd` over TCP. Anything that depends on the app using it, or on the platform it runs on, stays with the caller.

## In the package

| Area | Contents |
| --- | --- |
| Transport | The ADB message format, `CNXN`, `OPEN`, `WRTE`, `OKAY`, `CLSE`, streams multiplexed over one connection |
| Classic authentication | `AUTH` with an RSA key: signing the device's token, offering the public key when the device does not know it yet |
| Keys | Creating an RSA key pair and the certificate used for TLS. Storing them is the caller's job: the package takes and returns bytes |
| TLS | `STLS` and the switch to TLS 1.3 on the open socket |
| Pairing | Android 11+ pairing with a six-digit code: TLS 1.3, the keying material exporter, SPAKE2, the exchange of peer info |
| Services | Shell with a deadline; the sync protocol (stat, pull, push); `pm install` streamed with progress; install of several APKs in one session |
| Watchdog | A deadline per command and a stall guard for transfers, because a device that disappears leaves a half-open socket that never fails by itself |
| Probes | A `CNXN` probe that never authenticates, and a check whether the device already trusts a key that never sends the public key; neither makes the device ask its user anything |
| Discovery helpers | The mDNS service names (`_adb._tcp`, `_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp`) and a parser for their announcements |
| Errors | One sealed error type with stable codes, see [errors.md](errors.md) |

## Left to the caller

- **Finding devices.** mDNS needs platform APIs on iOS (`NWBrowser`, the Local Network permission) and multicast setup on some Android devices; a subnet scan is a product decision. The caller finds addresses and hands them to the package.
- **Which addresses to connect to.** The package connects where it is told. Restricting connections (for example to private addresses) is the caller's policy.
- **Key storage.** Keychain, a no-backup directory, a file: the caller decides.
- **What runs on the device.** The package runs commands and moves bytes; parsing `pm`, `dumpsys` or `getprop` output belongs to the app.
- **Background execution.** Keeping a connection alive while the app is in the background is a platform matter.

## Not planned

USB, the adb server protocol (`host:` services through port 5037), port forwarding and reverse forwarding, `logcat` streaming helpers, the web.
