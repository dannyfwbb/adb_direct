# Device tests

Run against a real adbd. Skipped unless `ADB_DIRECT_TEST_HOST` is set.

| Variable | Meaning |
| --- | --- |
| `ADB_DIRECT_TEST_HOST`, `ADB_DIRECT_TEST_PORT` | Where adbd listens in classic mode (port 5555 on the device, or a forwarded port) |
| `ADB_DIRECT_TEST_KEY` | A PEM private key the device already trusts |

With an Android emulator and the SDK's `adb`:

```bash
adb -s emulator-5554 tcpip 5555
adb -s emulator-5554 forward tcp:15555 tcp:5555
ADB_DIRECT_TEST_HOST=127.0.0.1 ADB_DIRECT_TEST_PORT=15555 \
ADB_DIRECT_TEST_KEY=$HOME/.android/adbkey dart test -t device
```

The emulator trusts the SDK's own key (`~/.android/adbkey`). The tests never change the device: they read, run harmless commands and download from `/dev/zero`.

## TLS (wireless debugging)

On an Android 11+ emulator or device with Developer options → Wireless debugging on, find the connection port (the screen's "IP address & Port", or `ss -ltnp | grep adbd` as root) and forward it:

```bash
adb -s emulator-5554 forward tcp:15556 tcp:<port>
ADB_DIRECT_TEST_HOST=127.0.0.1 ADB_DIRECT_TEST_TLS_PORT=15556 \
ADB_DIRECT_TEST_KEY=$HOME/.android/adbkey dart test -t device test/device/tls_device_test.dart
```

The key must be trusted by the device (paired, or allowed over a classic connection). `ADB_DIRECT_TEST_TLS_CERT_OUT=<file>` saves the device's certificate.

## Pairing

Pairing needs a person to open "Pair device with pairing code", so it is a tool, not a test:

```bash
adb -s emulator-5554 forward tcp:15557 tcp:<pairing port>
dart run tool/pair.dart 127.0.0.1 15557 <code> /tmp/paired.pem 15556
```

It pairs a key (made if the file is missing), then connects over TLS with it. The key shows up under "Paired devices" as `adb_direct@pair`.
