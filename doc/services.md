# Forwarding and device services

## Any service as a stream

`adb.open(service)` opens any device service and returns an `AdbStream`: `input` is what the device sends, `write` sends (the future completes when the device took it), `flush` waits until everything written was acknowledged, `close` ends both directions. Cancelling the subscription to `input` closes the stream too, so read with `listen` (not `first`) when you still want to write afterwards.

## Forward

```dart
final forward = await adb.forward('tcp:8080');          // or localabstract:<name>, jdwp:<pid>, …
print('http://127.0.0.1:${forward.port}/');             // each connection opens tcp:8080 on the device
await forward.close();
```

There is no adb server: the forward is a `ServerSocket` in this process, one device stream per local connection, with flow control both ways (a slow side slows the other down instead of filling memory). It ends with `close()` or with the connection. A service the device refuses closes the local connection. While the device is not taking data, a local peer that hangs up is noticed only once the device moves again (or the connection's liveness check gives up).

It listens on the loopback address by default. Anything on this machine can connect to it, as with `adb forward`; on a phone that means other apps too, so forward only what you would expose that way (`jdwp:` and DevTools sockets give control over an app).

## Reverse

```dart
final web = await adb.reverse.toLocalPort('tcp:8081', 8081);  // device:8081 → 127.0.0.1:8081 here
final any = await adb.reverse.toLocalPort('tcp:0', 3000);     // any free device port
print(any.devicePort);
final custom = await adb.reverse.add('localabstract:myapp', (stream) {
  stream.input.listen((data) => stream.write(data));          // handled in code, no local socket
});
print(await adb.reverse.list());
await adb.reverse.removeAll();
```

The device opens a stream to us for each connection made to its side. A handler may be `async`; if it fails, its stream is closed. Only targets set up through `adb.reverse` are accepted (a rebind or a removal stops accepting the old one, and at most 256 device-opened streams run at once); any other `OPEN` from the device is refused (an unchecked one would let a device reach whatever the host can). Reverse forwards live as long as the connection. Refusals (`cannot rebind existing socket` with `rebind: false`, a bad spec, removing what does not exist) are `AdbServiceUnavailableException` with the device's text.

## adbd's own services

```dart
final answer = await adb.daemon.root();
if (answer.restarting) adb = await AdbConnection.waitFor(host, port, key: key);
```

| Call | Outcomes |
| --- | --- |
| `root()` | `restarting`, `unchanged` (already root), `refused` (production build) |
| `unroot()` | `restarting`, `unchanged` |
| `tcpip(port)`, `usb()` | `restarting` |
| `reboot([target])` | `restarting`; target `bootloader`, `recovery`, `sideload`, `sideload-auto-reboot`, `fastboot` |
| `remount()`, `disableVerity()`, `enableVerity()` | `refused` for adb's known refusals (not root, a locked bootloader, a user build, no such tool), otherwise `done`; `output` has adbd's text either way |

When adbd restarts, the call closes the connection and returns `restarting`; an answer cut off by the restart counts as one too. `usb()` over the network ends network debugging until someone turns it on again on the device.

Every call but `reboot` takes a `timeout`: 30 s, or 2 minutes for `remount`, `disableVerity` and `enableVerity`. A service still silent then gets its stream closed and the call throws `AdbTimeoutException`, unless what it printed already tells the outcome. The connection stays usable. Output past 1 MiB is an `AdbCommandException`.

`AdbConnection.waitFor` connects again with a pause that grows from 250 ms to 2 s (the last attempt may run past `timeout` by one connect), retrying only "not there yet" failures (unreachable, refused, closed, timeouts, a garbled exchange while adbd starts). A device that refuses the key fails at once. After `tcpip` or `root` adbd is back in about a quarter of a second on an emulator; after a reboot it takes as long as booting and bringing the network up.

## Debugging

| Call | What |
| --- | --- |
| `debug.trackJdwp()` | Lists of debuggable pids, a new one at each change |
| `debug.trackApps()` | Lists of `AdbAppProcess` (pid, debuggable, profileable, architecture, user, process name, packages, uid), Android 12+ |
| `debug.jdwp(pid)` | A stream to that process's JDWP agent, from the handshake on |
| `debug.logcat(arguments: ['-d'])` | Log lines; without `-d` it follows until cancelled |
| `debug.screencap()` | A PNG; `timeout` (30 s) and `maxBytes` (128 MiB) bound it |
| `debug.bugreport(file, onProgress: …)` | A bug report zip (Android 7+): `bugreportz -p`, then a pull, then the device copy is removed. `stallTimeout` (5 minutes without output) ends the wait |

## Backup, restore and sideload

`backup.create(arguments)` streams an `adb backup` archive and `backup.restore(archive)` sends one; the device asks its user to confirm on screen, and Android has deprecated both. `recovery.sideload(file)` serves an OTA package to a device in recovery's "Apply update from ADB" (blocks in the device's order, adb's 64 KiB block size, the pre-4.4 whole-file method when the device lacks `sideload-host`); `rescue: true` does the same in rescue mode.
