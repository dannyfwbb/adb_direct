# Security

adb_direct talks to devices over the network, holds the keys a device trusts, and parses what devices and networks send. Reports of weaknesses are welcome.

## Reporting a vulnerability

Report it privately through GitHub: **Security → Report a vulnerability** on [dannyfwbb/adb_direct](https://github.com/dannyfwbb/adb_direct/security/advisories/new). Please do not open a public issue for it.

Say what is affected (versions, platform, the call or protocol path), how to reproduce it, and what an attacker gains. A first answer comes within a week. Once a fix is released, the advisory is published with credit to the reporter, unless they prefer otherwise.

## Supported versions

Fixes go into the latest release of the current major version.

| Version | Supported |
| --- | --- |
| 1.x (latest) | yes |
| older | no |

## In scope

- Anything a device, an adb server, a network peer or an mDNS announcement can send that makes the package crash, hang, use unbounded memory or CPU, write outside the paths it was given, run commands it was not asked to run, or accept a stream it should refuse.
- Key handling: private keys leaving the process, or signatures and certificates made wrongly.
- Pairing: anything that lets a third party learn or bypass the pairing code.

## Known limits, not vulnerabilities

These follow from the ADB protocol and are documented:

- adb has nothing to verify a device's TLS certificate against; `AdbConnection.deviceCertificate` lets an app remember it and compare it later.
- On a classic connection (port 5555) traffic is not encrypted; use wireless debugging (TLS) where the device offers it.
- A device that is trusted with a key can be asked to do anything the shell user can; deciding which devices to connect to is the application's policy.
