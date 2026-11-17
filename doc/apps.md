# Apps

```dart
await adb.packages.install(AdbApk.file(File('app.apk')), onProgress: (done, total) {});
await adb.packages.installMultiple([AdbApk.file(base), AdbApk.file(split)]);
await adb.packages.uninstall('com.example.app');
```

## How an APK gets there

| Device | Way | Like |
| --- | --- | --- |
| Android 11+ (`abb_exec`) | streamed straight to the package manager over Binder | `adb install` today |
| Android 7-10 (`cmd`) | streamed to `cmd package install -S <size>` | `adb install` on those versions |
| Older | pushed to `/data/local/tmp`, `pm install`, then removed | `adb install` before streaming |

`AdbApk` is a name, a size and a way to read the bytes: `AdbApk.file`, `AdbApk.bytes`, or your own stream (it must yield exactly `size` bytes; a mismatch fails with `ArgumentError`).

## Several APKs, several apps

- `installMultiple` installs one app made of a base and its splits in one package manager session: created, filled, committed; any failure abandons the session, so nothing half-installed is left.
- `installMultiPackage` installs several apps atomically (all or none), on Android 10 and later. Older devices throw `AdbNotSupportedException`, and so do devices without install sessions at all (before Android 5).

## Options

`AdbInstallOptions`: `allowDowngrade` (`-d`), `grantPermissions` (`-g`), `allowTest` (`-t`), `user`, `installerPackage` (`-i`), `instant`, `abi`, `bypassLowTargetSdkBlock` (Android 14 refuses apps targeting very old SDKs without it), `extraArguments`. Replacing an installed app is always allowed (`-r`).

Downgrading: Android 12 and later allow `-d` only for debuggable apps (or on debuggable builds); a release app still fails with `INSTALL_FAILED_VERSION_DOWNGRADE`.

## Results

Success returns normally. Anything else throws `AdbInstallException`:

- `failureCode`: the package manager's code (`INSTALL_FAILED_VERSION_DOWNGRADE`, `INSTALL_PARSE_FAILED_NOT_APK`, `INSTALL_FAILED_INVALID_APK` for splits without their base, `INSTALL_FAILED_INSUFFICIENT_STORAGE`, `DELETE_FAILED_INTERNAL_ERROR` for an app that is not installed, …), or null when its answer had none (a stack trace, for example);
- `output`: its answer, exactly.

The exit status of `pm` is never trusted: it often exits 0 after refusing.

Note that `uninstall --user` answers `Success` even for a user that does not exist (Android 14).

## Progress and time

`onProgress` reports bytes the device has acknowledged, so 100% means the APK arrived. An upload that makes no progress for `AdbConnectOptions.transferStallTimeout` (30 s) fails with `AdbTimeoutException`. After the last byte the package manager verifies the app in silence: it may take up to `AdbConnectOptions.packageManagerTimeout` (five minutes) to answer before the install fails with `AdbTimeoutException`. Slow TVs can take a minute or more for a big app; that is not a stall.

An install cannot be cancelled on its own; closing the connection ends it. On old devices the temporary file is removed whatever happens.
