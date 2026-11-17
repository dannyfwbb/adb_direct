# Package manager answers

Exact answers of `cmd package` on the Google TV emulator (Android 14), recorded on 2026-11-17 with the test APKs in `../apks`. The tests parse them.

| File | Command |
| --- | --- |
| `install_create.txt` | `install-create -r -S 5` |
| `install_abandon.txt` | `install-abandon <id>` |
| `install_downgrade.txt` | `install` of version 1 over version 2, without `-d` |
| `uninstall_success.txt` | `uninstall` of an installed app |
| `uninstall_not_installed.txt` | `uninstall` of an app that is not there |
| `uninstall_other_user.txt` | `uninstall --user 10` (a user that does not exist): `Success` |
| `stack_trace.txt` | `disable-user` of an unknown package: no `Success`, no `Failure`, a Java stack trace |
