# adb_direct

An ADB client in pure Dart that talks to `adbd` on an Android device over the network. No `adb` binary, no adb server, no platform channels: one `dart:io` implementation for Android, iOS, macOS, Windows and Linux.

> **Status: in development.** Nothing is published on pub.dev yet and the API will change.

## What it does

- **Classic network debugging** (port 5555): connect, RSA authentication, the "Allow debugging?" approval on the device.
- **Wireless debugging** (Android 11+): pairing with a six-digit code (SPAKE2 over TLS 1.3) and TLS connections.
- **Shell** with a deadline per command.
- **Files and apps**: pull and push over the sync protocol, APK install streamed with progress, install of split APKs.
- **Probes that never ask the user**: check whether an address speaks ADB, and whether a device already trusts a key, without showing "Allow debugging?" on anyone's screen.
- **Typed errors** with stable codes, see [doc/errors.md](doc/errors.md).

The goal is everything a user of `adb` needs from a device: forwarding, interactive shells, sync v2, reboot modes, sideload and the rest. [doc/scope.md](doc/scope.md) lists every area and its state. USB needs a platform API, so the package offers a transport interface for it instead.

## Platforms

Every platform with `dart:io`. Not the web: browsers do not open raw TCP sockets.

## Documentation

[doc/README.md](doc/README.md) lists the documents: scope, protocol notes and errors.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
