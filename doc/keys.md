# Keys

A device trusts a key, not an app: the first connection with a new key shows "Allow debugging?" on the device, and the user may tick "Always allow". Keep the same key pair from then on, or the device asks again.

```dart
// Once: create a key pair and store it where your app keeps secrets.
final keys = await AdbKeyPair.generate(comment: 'my-app@phone');
await store.write('adbkey', keys.toPem());

// Every later run: read it back.
final keys = AdbKeyPair.fromPem(await store.read('adbkey'), comment: 'my-app@phone');
```

- `AdbKeyPair.generate` creates an RSA-2048 key (exponent 65537) in a background isolate; it takes well under a second on a desktop.
- `toPem` writes PKCS#8, the format of desktop adb's `~/.android/adbkey`; `fromPem` reads PKCS#8 and the PKCS#1 files older adb wrote. Keys made by `adb keygen` work unchanged, so a tool can reuse the key a desktop already uses, and every device that trusts it.
- `publicKey` is the key in adb's own format: `publicKey.encode()` is exactly what `adb pubkey` prints and what `adbkey.pub` holds. `AdbPublicKey.parse` reads such text.
- `publicKey.md5Fingerprint` is the fingerprint the device shows in its dialog (`AB:CD:…`), handy to show the user which prompt to accept.
- `spkiSha256` is how a device names the key in the trusted-key list it sends during a TLS handshake (wireless debugging).
- `fromPem` and `AdbPublicKey.parse` throw `FormatException` for anything that is not a consistent 2048-bit RSA key: a broken or tampered file fails when it is read, not later on a device.
- `AdbPublicKey`'s `==` includes the comment; `hasSameKey` compares the keys alone, as a device does.
- The comment (`user@host` by convention) is shown on the device and stored with the key there; it plays no part in authentication.

Storing the key is your app's decision. A key that ends up in a backup and is restored on another phone makes that phone trusted too, which is usually not what users expect: keep it out of backups.
