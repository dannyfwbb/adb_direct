# Fixtures

Exchanges recorded with a real adbd, replayed in tests by the fake adbd in `test/support/fake_adbd.dart` and loaded by `test/support/fixtures.dart`.

## Format

One JSON object per line.

Line 1 is a header:

| Key | Meaning |
| --- | --- |
| `fixture` | The name, the path under this folder without `.jsonl` |
| `device` | The device and Android version |
| `adbd` | The adbd module and version (`pm list packages --apex-only --show-versioncode`) |
| `recorded` | Date |
| `note` | What the exchange shows |
| `starts` | `connection` (from the first `CNXN`) or `online` (after a completed handshake) |
| `host_features` | For `online` fixtures: the features the recording client announced, which decide how the device behaves |

Every other line is one packet:

| Key | Meaning |
| --- | --- |
| `dir` | `>` sent to the device, `<` sent by the device |
| `cmd` | `CNXN`, `AUTH`, `OPEN`, `OKAY`, `CLSE`, `WRTE` or `STLS` |
| `arg0`, `arg1` | The arguments, as numbers |
| `data` | The full payload in hex |
| `raw` | The whole packet as it crossed the wire, header included, in hex. Checked against the other fields when loaded; tests feed these bytes to the reader |

## Contents

Fixtures contain no private keys. `AUTH` signatures are public by nature and useless without the key; tokens are random.

| Fixture | Shows |
| --- | --- |
| `handshake/trusted_key` | A trusted key: token, signature, the device's `CNXN` with its banner |
| `handshake/untrusted_key` | An unknown key: a wrong signature is answered with a new token |
| `shell/v1` | `shell:` merges stdout and stderr; the device sends `CLSE` twice |
| `shell/v2` | Shell protocol v2 packets: stdout, stderr, exit status 3 |
| `shell/exec` | `exec:` raw output |
| `streams/unknown_service` | An unknown service is refused with `CLSE(0, id)` |
| `streams/delayed_ack_open` | Delayed acknowledgements: windows in `OPEN` and `OKAY` |
| `streams/delayed_ack_missing_window` | With delayed acknowledgements, an `OPEN` without a window is refused |
| `streams/banner_nul_hides_last_feature` | A host banner ending in NUL loses its last feature |

## Other fixtures

- `apks/`: tiny test APKs and their manifests, built by `tool/build_test_apks.sh`.
- `pm/`: package manager answers recorded from a device (see `pm/README.md`).
- `keys/`: test-only key pairs made with `adb keygen`.

## Recording

Recorded on 2026-11-17 from the Google TV emulator (Android 14). Re-record when adbd behaviour changes, keep the old files when the difference matters (devices in the field run old adbd), and never edit packets by hand.
