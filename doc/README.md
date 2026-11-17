# Documentation

| Document | What it covers |
| --- | --- |
| [scope.md](scope.md) | What the package does, what it leaves to the caller, and why |
| [protocol.md](protocol.md) | The parts of the ADB protocol the package implements, as notes for readers of the code |
| [errors.md](errors.md) | The error type, its codes and when each one is raised |
| [keys.md](keys.md) | Key pairs: creating, storing, reusing adb's own keys, fingerprints |
| [connection.md](connection.md) | Connecting, the approval prompt, wireless debugging (TLS), probes, streams, flow control, a device that goes away, options, tracing |
| [pairing.md](pairing.md) | Pairing with a code or a QR code (Android 11+ wireless debugging) |
| [shell.md](shell.md) | Running commands, raw `exec`, interactive sessions |
| [files.md](files.md) | Stat, list, read and write files; local files and directories |
| [apps.md](apps.md) | Install, split APKs, several apps at once, uninstall, results |

API documentation is generated from the code with `dart doc` once the package has an API.
