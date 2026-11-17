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
