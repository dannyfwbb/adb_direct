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

## Services that restart adbd

Run device test files one at a time (`dart test -j 1 -t device …`): `tcpip`, `root` and `unroot` restart adbd under any other file running against the same device.


`tcpip`, `root` and `unroot` restart adbd, which drops `adb forward` on the host along with it. Use the emulator's own port redirection instead, which does not go through adbd:

```bash
adb -s emulator-5556 emu redir add tcp:15555:5555   # TV emulator
adb -s emulator-5554 emu redir add tcp:15558:5555   # phone emulator (adbd on TCP 5555)
ADB_DIRECT_TEST_HOST=127.0.0.1 ADB_DIRECT_TEST_PORT=15558 ADB_DIRECT_TEST_ROOTABLE=1 \
ADB_DIRECT_TEST_KEY=$HOME/.android/adbkey dart test -t device test/device/daemon_device_test.dart
```

Set `ADB_DIRECT_TEST_ROOTABLE=1` only for a device that may be rooted and unrooted (the phone emulator). Reboot has no test: a rebooted emulator listens on TCP only after `adb tcpip` again. JDWP needs a debuggable app running; `ADB_DIRECT_TEST_BUGREPORT=1` adds the bug report (minutes on a real device).

## mDNS

`test/device/mdns_device_test.dart` browses a service that `tool/mdns_publish.py` publishes through the local Avahi daemon (Linux, `python3` with the `dbus` module, no root). It uses its own type `_adbdirect-test._tcp`, so it touches no device:

```bash
ADB_DIRECT_TEST_MDNS=1 dart test -t device test/device/mdns_device_test.dart
```
