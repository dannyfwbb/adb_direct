# Through an adb server

Where `adb` runs anyway (a desktop), `AdbServer` talks to its server on port 5037. It reaches every device the server knows, USB ones included, which Dart cannot open itself.

```dart
final server = AdbServer();                       // 127.0.0.1:5037
print(await server.version());                    // 41 for "1.0.41"
for (final d in await server.devices()) {
  print('${d.serial} ${d.state} ${d.model}');
}
await server.connect('192.168.0.20');             // adb connect
final adb = await server.device('emulator-5554'); // an AdbConnection
print((await adb.shell.run('getprop ro.product.model')).stdoutText);
```

`server.device(serial)` returns an `AdbConnection` with the same services as a direct one: shell, files, apps, forwarding, debugging. Each stream is a socket to the server that asks it to relay one service (`host:transport:<serial>`, then the service). The connection ends (`done`, `closeReason`) when the server stops listing the device as online. The server holds the device's authentication, so `acceptedKey` is null; reverse forwarding reaches local ports on this machine (`toLocalPort`, the server connects them, and keeps them until removed or the device goes) but not handlers in code; `acknowledgedBytes` counts what the server took, as the device's acknowledgements stay between them.

| Call | Server request |
| --- | --- |
| `version()` | `host:version` |
| `devices()` | `host:devices-l` |
| `trackDevices()` | `host:track-devices-l` (a new list at every change) |
| `connect(host, port)`, `disconnect(…)` | `host:connect:…`, `host:disconnect:…` |
| `pair(host, port, code)` | `host:pair:…` (the server's own key) |
| `device(serial)` | `host-serial:<serial>:features`, then `host:transport:<serial>` per stream |

Measured on an emulator, push and pull through the server run as fast as `adb push` and `adb pull` (about 770 and 280 MiB/s).

## Your own transport

`AdbConnection.connectTransport(open, key: …)` speaks ADB over any `AdbTransport`: a byte pipe with `start`, `write`, `close`, `destroy`, and `startTls` for wireless debugging (a USB transport throws `AdbNotSupportedException` there). `open` is called once per attempt, so a TLS port can be retried with the next key. `example/usb_transport_outline.dart` shows a USB transport over an adb interface's two bulk endpoints.
