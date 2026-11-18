# Apps

```dart
await adb.packages.install(AdbApk.file(File('app.apk')), onProgress: (done, total) {});
await adb.packages.installMultiple([AdbApk.file(base), AdbApk.file(split)]);
await adb.packages.uninstall('com.example.app');

final apps = await adb.packages.list(system: false);        // name, path, version code, installer, user ids
await adb.packages.setEnabled('com.example.app', enabled: false);
await adb.packages.clearData('com.example.app');
await adb.packages.grantPermission('com.example.app', 'android.permission.CAMERA');
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

## APEX modules

An `AdbApk` whose name ends with `.apex` is installed as an APEX module (`--apex`), as `adb install` decides. Modules are staged and take effect after the next reboot; the device must list `apex` (Android 10+, else `AdbNotSupportedException`), and most builds accept only modules signed for them. A module goes alone through `install`, or as its own entry in `installMultiPackage`, which then stages the whole set (`--staged`); `installMultiple` refuses it. Android 14 takes about a minute to refuse a file that is not a module (`Failure [failed to retrieve SessionInfo]`), as with `adb`.

## Incremental installs

Like `adb install --incremental` (Android 11+ with incremental delivery): the package manager answers as soon as it has the blocks it needs, the app can start at once, and the rest arrives in the background, each block fetched on demand when the app reads it first.

```dart
final install = await adb.packages.installIncremental([
  AdbIncrementalApk.file(File('app.apk')),          // reads app.apk.idsig next to it
  AdbIncrementalApk.file(File('split_config.apk')),
]);
// Installed. Keep the connection open until every block has arrived:
await install.done;
```

- Each APK needs its APK Signature Scheme v4 file (`.idsig`): `apksigner sign --v4-signing-enabled true` writes it, and the Android Gradle plugin does for debug builds. It holds the hash tree the device checks every block against. A file without one is sent whole first.
- `done` completes when the device says it has everything. Closing the connection earlier leaves the app incomplete: reads of missing parts fail on the device until the app is installed again. `isComplete`, `blocksSent` and `totalBlocks` tell how far serving got; `close()` stops it.
- Blocks are compressed with LZ4 when that saves at least 5%, and the parts of the APK the package manager reads first (signing block, central directory, manifest, resources, native libraries, the head of `classes.dex`) go first, as `adb` does.
- Devices without `abb_exec` (Android 10 and older) throw `AdbNotSupportedException`; devices without incremental delivery refuse with `AdbInstallException`. Options (`AdbInstallOptions`) apply as for `install`.

## App management

Typed helpers over `pm`, through the shell:

| Call | `pm` | Notes |
| --- | --- | --- |
| `list({system, enabled, user, apex})` | `list packages -f -i [-U] [--show-versioncode]` | `AdbPackageInfo`: name, base APK path, installer, user ids (Android 8+), version code (Android 9+); `apex: true` lists APEX modules (Android 10+) |
| `paths(package)` | `path` | The base APK first, then splits; empty when not installed |
| `setEnabled(package, enabled:)` | `enable`, `disable-user` | A package or a component (`package/class`) |
| `clearData(package)` | `clear` | |
| `grantPermission`, `revokePermission` | `grant`, `revoke` | Runtime permissions the app asks for |

Each takes `user`. A refusal throws `AdbCommandException` with the command's exact `output` and `exitCode`; its message carries the useful line of a Java stack trace (`java.lang.IllegalArgumentException: Unknown package: …`). Versions differ in what they refuse: Android 14 grants a permission to an unknown package without a word, Android 17 grants one the app did not ask for; an unknown permission is refused everywhere.

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
