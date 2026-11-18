# Sync

`lz4_pull.bin`: the payloads of the `DATA` chunks adbd sent for `RCV2` with flag 2 (LZ4), concatenated: one LZ4 frame with linked 64 KiB blocks and no checksums (FLG `0x40`, BD `0x40`). The file was the text of `sample()` in `test/compression/lz4_test.dart` (186 366 bytes), pushed first. Google TV emulator (Android 14, adbd `com.google.android.adbd` 340090000), 2026-11-18.
