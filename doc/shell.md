# Shell

## Running a command

```dart
final result = await adb.shell.run('pm list packages -3');
print(result.exitCode);      // 0
print(result.stdoutText);    // package:com.example…
print(result.stderrText);
```

- The command runs with `sh -c`. On Android 7 and later its stdin is empty, so commands that read stdin end at once; older devices run commands on a PTY with no way to end stdin, so avoid commands that wait for input there, and expect `\r\n` line ends.
- `timeout` (30 s by default, opening included) stops a command that runs too long: the call throws `AdbTimeoutException` and the connection stays usable.
- `maxOutputBytes` (16 MiB) bounds memory: past it the command is stopped and `result.truncated` is true.
- On Android 7 and later (shell protocol v2) stdout and stderr come separately and the exit status is exact. On older devices they arrive merged in `stdout`; the exit status is learned by printing it after the command behind a random marker, so it is null when the command left the shell (`exit 3`).
- Quote arguments with `shellQuote`: `adb.shell.run('ls ${shellQuote(path)}')`.

## Raw bytes: `exec`

`adb.shell.exec('screencap -p')` returns a stream with the command's exact bytes, no PTY and no protocol, for binary output. Write to it to feed stdin; closing the stream ends the command.

## Interactive sessions

```dart
final shell = await adb.shell.start();               // a login shell with a PTY
shell.stdout.listen((bytes) => terminal.write(bytes));
await shell.resize(rows: 40, columns: 120);
await shell.write(utf8.encode('top -n 1\n'));
print(await shell.exitCode);
```

`start(command: 'wc -c', pty: false)` runs a command with separate stdout and stderr; `closeStdin()` ends its input. Nothing is read from the device until `stdout` has a listener, and pausing a `stdout` or `stderr` subscription pauses the device. `exitCode` completes after the listeners have received all output; it is null when the status is unknown, and `closeReason` tells a failed session apart.

Without shell protocol v2 (Android 6 and older) a session always has a PTY and has no stderr, exit status or window size; `pty: false` throws `AdbNotSupportedException` there.

## System properties

`adb.properties` wraps `getprop` and `setprop`:

```dart
final sdk = await adb.properties.sdkLevel();            // 34; asked once per connection
final model = await adb.properties.get('ro.product.model');
final all = await adb.properties.all();                 // every property the shell user can read
final serial = await adb.properties.serialNumber();     // ro.serialno, else ro.boot.serialno; what `adb get-serialno` shows over USB
await adb.properties.set('debug.myapp.verbose', '1');
```

`get` returns null for an unset property (and for an empty one: `getprop` prints both alike). `all` handles values that run over several lines. `set` throws `AdbCommandException` when the device refuses; most properties are writable only by the system, and devices before Android 9 refuse in silence, so read the value back where it matters.
