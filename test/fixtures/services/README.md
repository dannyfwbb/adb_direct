# Device service answers

Exact answers of adbd services, recorded on 2026-11-17 from the Google TV emulator (Android 14, a user build) and the phone emulator (Android 17, userdebug), as `service → answer`. Keys with a note in parentheses are the same service in another situation. The unit tests replay them through the fake adbd.

Binary answers of the tracking services, one frame each (`<hex4 length><payload>`):

- `track_jdwp.bin`: `track-jdwp` on the phone emulator with one debuggable app running (pid 8646).
- `track_app_phone.bin`: `track-app` on the phone emulator, the same moment. The debuggable app's package name was replaced by `com.example1`, which has the same length, so the protobuf framing is untouched.
- `track_app_tv.bin`: `track-app` on the TV emulator: three processes, no package names.
