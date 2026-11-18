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
| `list_packages_tv.txt` | `pm list packages -f -i -U --show-versioncode`, a few lines (paths with `=`, two user ids) |
| `list_apex_tv.txt` | `pm list packages -f -i --show-versioncode --apex-only`, the first lines |
| `path.txt` | `pm path com.google.android.webview` |
| `clear_unknown_stderr.txt` | `pm clear` of an unknown package: `Failed` on stderr, exit status 1 |

Also seen on 2026-11-18 (not stored): `pm grant` of an unknown package prints nothing and exits 0 on Android 14, but fails with `Failure [package not found]` on the Android 17 phone emulator.

Android 7 (API 24 emulator, 2026-11-18): `cmd package install-commit <id>` prints nothing when it succeeds; `install-create` and `install-write` print `Success: …` as later versions do.
