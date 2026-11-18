# Documentation

| Document | What it covers |
| --- | --- |
| [scope.md](scope.md) | What the package does, what it leaves to the caller, and why |
| [protocol.md](protocol.md) | The parts of the ADB protocol the package implements, as notes for readers of the code |
| [errors.md](errors.md) | The error type, its codes and when each one is raised |
| [keys.md](keys.md) | Key pairs: creating, storing, reusing adb's own keys, fingerprints |
| [connection.md](connection.md) | Connecting, the approval prompt, wireless debugging (TLS), probes, streams, flow control, a device that goes away, options, tracing |
| [discovery.md](discovery.md) | Finding devices: mDNS browsing, platform browsers, scanning |
| [pairing.md](pairing.md) | Pairing with a code or a QR code (Android 11+ wireless debugging) |
| [shell.md](shell.md) | Running commands, raw `exec`, interactive sessions, system properties |
| [files.md](files.md) | Stat, list, read and write files; compression; local files and directories |
| [services.md](services.md) | Forward, reverse, root/reboot/tcpip and waiting for the device, JDWP, process tracking, logcat, screenshots, bug reports, backup, sideload |
| [server.md](server.md) | Through a running adb server; your own transport (USB) |
| [compatibility.md](compatibility.md) | What differs on old devices and how the package handles it |
| [apps.md](apps.md) | Install, split APKs, several apps at once, APEX modules, incremental installs, uninstall, listing and managing apps, results |

Every public class and member is documented in the code; `dart doc` generates the API reference, which pub.dev shows.
