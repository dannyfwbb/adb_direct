# Examples

Each example connects with `adbkey.pem` from the working directory (made on first use, see `key.dart`); the device asks "Allow debugging?" the first time. Arguments are the device's address and port: 5555 for classic network debugging (`adb tcpip 5555`), or the port under Developer options → Wireless debugging → "IP address & Port" once paired.

| Example | Like | Run |
| --- | --- | --- |
| [adb_direct_example.dart](adb_direct_example.dart) | `adb connect`, `adb shell uptime`, `adb shell ls` | `dart run example/adb_direct_example.dart <host> <port>` |
| [shell.dart](shell.dart) | `adb shell`, `adb shell <command>`, `adb logcat` | `dart run example/shell.dart <host> <port> [--log \| command…]` |
| [files.dart](files.dart) | `adb push`, `adb pull` (files and folders, LZ4) | `dart run example/files.dart <host> <port> push <local> <remote>` |
| [apps.dart](apps.dart) | `adb install`, `install-multiple`, `install --incremental`, `pm list packages`, `adb uninstall` | `dart run example/apps.dart <host> <port> install <apk>…` |
| [pair.dart](pair.dart) | `adb pair`, then `adb connect` over TLS | `dart run example/pair.dart <host> <pairing port> <code> [port]` |
| [discover.dart](discover.dart) | `adb mdns services`, plus a silent scan of a subnet | `dart run example/discover.dart [192.168.0]` |
| [platform_browser.dart](platform_browser.dart) | — | Plugging a platform's service browser (iOS `NWBrowser`, Android NSD) into discovery |
| [usb_transport_outline.dart](usb_transport_outline.dart) | `adb -d` | The shape of a USB transport from a platform plugin |
