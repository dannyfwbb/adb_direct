# Old devices

The package decides by the features a device announces, and falls back where the device has less. The one exception is `pm`'s options, which no feature announces: `packages.list` asks for them by the API level (`ro.build.version.sdk`). Checked on emulators of Android 4.4, 5.0, 7.0, 9, 14 (TV) and 17:

| Android | What differs | What the package does |
| --- | --- | --- |
| 4.4 | no `exec:`; `shell:` runs in a PTY; no install sessions; protocol with checksums | `shell.run` uses `shell:` and turns CR LF back into LF; logcat over `shell:`; screenshots through a file on the device; `install` pushes the APK and runs `pm install`; `installMultiple` says "not supported" |
| 5.0-6.0 | no shell protocol v2 | `shell.run` uses `exec:` (stdout and stderr together, no PTY) with an empty stdin; the exit status comes from a marker the shell prints after the command |
| 7.0 | `cmd`, shell v2; `install-commit` prints nothing when it succeeds | streamed installs; an empty commit answer counts as success over `cmd` while the connection is up (Android 9 prints `Success`) |
| 7.0-9 | no `fixed_push_mkdir`: pushing into a missing directory fails | `pushDirectory` makes the directories first, as adb does; a single `pushFile` needs its parent to exist |
| before 8.0 | no `stat_v2`; `pm list packages` has no `-U` | `stat(followLinks: true)` says "not supported"; sizes stop at 4 GiB; `list` gives no user ids |
| before 9 | no `--show-versioncode` in `pm list packages` | `list` gives no version codes |
| before 10 | no `apex` feature, no `--apex-only` | APEX installs and `list(apex: true)` say "not supported" |
| before 11 | no `abb_exec`, no `sendrecv_v2` compression | installs go through `cmd`; `installIncremental` says "not supported"; compressed transfers go uncompressed |
| 9 and later | protocol without checksums, 1 MiB payloads | used when the device offers them |

Quirks of the devices themselves: the adbd of Android 5 and 7 emulators refuses `reverse` ("more than one device/emulator"); Android 9's `pm uninstall` of a missing app prints a Java stack trace (an `AdbInstallException` without a code); emulators before Android 7 have no toybox `nc` or `stty`.
