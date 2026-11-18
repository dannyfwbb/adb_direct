# Pairing

Android 11 and later can trust a key without a cable or a prompt: the user opens Developer options → Wireless debugging → "Pair device with pairing code", and the device shows a six-digit code and a pairing port (not the connection port).

```dart
final paired = await AdbPairing.pair(
  '192.168.0.20',
  37099,               // the pairing port from the dialog
  code: '482913',
  key: key,            // the key to trust from now on
);
print(paired.guid);    // adb-<serial>-<random>
final adb = await AdbConnection.connect('192.168.0.20', 41235, key: key);
```

The key's comment (`user@host` by default) is the name the device lists under "Paired devices". The connection port is the one under "IP address & Port"; it differs from the pairing port and both change when wireless debugging restarts. On the network they are announced as `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp`, which `AdbMdnsBrowser` finds (see [discovery.md](discovery.md)).

## QR codes

```dart
final qr = AdbPairingQr.random();
showQrCode(qr.text);   // WIFI:T:ADB;S:studio-…;P:…;;
final paired = await qr.pair(services: AdbMdnsBrowser().pairingServices(), key: key);
```

QR pairing has been run only against a test server so far (an emulator cannot scan). The device scans the code ("Pair device with QR code"), starts a pairing server and announces it on mDNS under `qr.serviceName`. `pair` waits on `services`, a stream of `AdbPairingService` (name, host, port) for `_adb-tls-pairing._tcp` from `AdbMdnsBrowser` or a platform browser (`pairingServices()` on any `AdbServiceBrowser`), for that name, then pairs with the password. It times out after `waitTimeout` (two minutes) when no device appears.

## Failures

| Exception | When |
| --- | --- |
| `AdbPairingException`, `reason: wrongCode` | The code does not match: the device's answer does not decrypt, or it closed the session after the client's key. On Android 17 the dialog stayed open and a second try with the right code paired. |
| `AdbPairingException`, `reason: protocol` | A malformed packet, a SPAKE2 message that is no curve point, or a failed TLS handshake on the pairing port |
| `AdbRefusedException` | Nothing listens on the port: the dialog was closed, or it is the wrong port |
| `AdbTimeoutException` | No answer within `timeout` (30 s) |
| `AdbCancelledException` | `cancelOn` completed first |
| `AdbNotSupportedException` | The platform's TLS gives no key log, which binding the code to the TLS session needs (see Platforms below) |

## Platforms

Pairing needs the TLS session's exporter secret, which `dart:io` delivers through its key-log callback. It works on Linux and on Android (checked from an app on an Android 17 emulator); macOS, Windows and iOS have not been checked.

## Debugging

`keyLog` receives the TLS key-log lines (NSS format) so a packet capture of the pairing can be decrypted in Wireshark. They are secrets: never log them in production.
