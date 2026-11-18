# adb_direct

An ADB client in pure Dart that talks to `adbd` on Android devices over the network. No `adb` binary, no adb server, no platform channels, no native code: one `dart:io` implementation for Android, iOS, macOS, Windows and Linux.

```dart
import 'dart:io';

import 'package:adb_direct/adb_direct.dart';

final key = await AdbKeyPair.generate(comment: 'me@my-app');   // keep key.toPem() somewhere safe
final adb = await AdbConnection.connect(
  '192.168.0.20', 5555,
  key: key,
  onWaitingForApproval: () => print('Allow debugging on the device'),
);

final result = await adb.shell.run('getprop ro.product.model');
print(result.stdoutText);

await adb.sync.pushFile(File('notes.txt'), '/sdcard/Download/notes.txt');
await adb.packages.install(AdbApk.file(File('app.apk')), onProgress: (done, total) {});
await adb.close();
```

## What it does

Everything `adb` does with a device over the network:

- **Connections**: classic network debugging (port 5555) with RSA keys and the "Allow debugging?" prompt; **wireless debugging** (Android 11+) with pairing by six-digit code or QR code and TLS connections; your own transport (USB through a platform plugin, a tunnel); or any device through a running adb server.
- **Shell**: commands with separate stdout and stderr, exit status, deadline and output limit; raw `exec`; interactive sessions with a terminal; logcat, screenshots, bug reports; system properties.
- **Files**: stat, list, pull and push of files and folders over sync v1 and v2, with progress, stall detection and LZ4 compression.
- **Apps**: streamed installs with progress, split APKs, several apps atomically, APEX modules, incremental installs; list, enable, disable, clear data, permissions, uninstall.
- **Networking**: port forwarding and reverse forwarding, to local ports or to your own code; any device service as a stream.
- **Device**: root and unroot, remount, reboot to any mode, `tcpip`/`usb`, waiting for the device to come back, JDWP and app process tracking, sideload, backup and restore.
- **Discovery**: an mDNS browser for `_adb._tcp`, `_adb-tls-connect._tcp` and `_adb-tls-pairing._tcp`, a hook for platform browsers, and **probes that never ask the user**: whether an address speaks ADB, and whether a device already trusts a key, without "Allow debugging?" on anyone's screen.

And what a library needs beyond `adb`: one sealed exception type with stable codes, deadlines and stall guards on every operation, detection of devices that went away without closing the socket, ADB flow control with delayed acknowledgements, cancellation, tracing, and keys compatible with desktop `adb` (`~/.android/adbkey`). Old devices (Android 4.4 and later) get the fallbacks `adb` uses.

[doc/scope.md](doc/scope.md) lists every area and its state.

## Install

```yaml
dependencies:
  adb_direct: ^1.0.0
```

## Platforms

Android, iOS, macOS, Windows and Linux: everything with `dart:io`, from Dart or Flutter. Not the web, where browsers open no raw TCP sockets.

- **Android** apps need the `INTERNET` permission.
- **iOS** apps need the Local Network permission. Browsing mDNS from Dart needs Apple's multicast entitlement; without it, browse with `NWBrowser` and pass the results in (see [doc/discovery.md](doc/discovery.md)).
- **USB** needs a platform API (USB Host on Android, libusb on desktops): implement `AdbTransport` over it (outline in `example/`).

Checked on Linux and on Android; the other platforms use the same `dart:io` code but have not been run yet.

## Documentation

- [doc/README.md](doc/README.md): connections, keys, pairing, discovery, shell, files, apps, services, the adb server, old devices, errors, protocol notes.
- [example/](example/README.md): runnable examples for each area.
- Every public class and member is documented in the API reference.

## Versioning

The package follows [semantic versioning](https://semver.org). Within a major version, public names and behaviour stay compatible, and no `AdbException` subclass or `AdbErrorCode` value is added, so an exhaustive `switch` over them keeps compiling; new failure kinds wait for the next major version. Members marked `@internal` and everything under `lib/src/` are not part of the API.

## Used by

Couchkit.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). The SPAKE2 used for pairing follows BoringSSL byte for byte, and the incremental install protocol follows AOSP's adb client; both are credited in [NOTICE](NOTICE).
