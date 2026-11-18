// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';

import '../compression/lz4.dart';
import '../protocol/banner.dart';

/// A compression method of sync v2: what `adb push -z` and `adb pull -z` choose from.
enum AdbCompressionMethod {
  /// Brotli (RFC 7932).
  brotli(1, AdbFeature.sendRecvV2Brotli),

  /// LZ4 frames.
  lz4(2, AdbFeature.sendRecvV2Lz4),

  /// Zstandard (RFC 8878).
  zstd(4, AdbFeature.sendRecvV2Zstd);

  const AdbCompressionMethod(this.flag, this.feature);

  /// The flag in `SND2` and `RCV2` requests.
  final int flag;

  /// The device feature that says the device supports it.
  final AdbFeature feature;
}

/// Compression for sync transfers: a [method] and the converters that do it on this side.
///
/// [lz4] is built in. Brotli and Zstandard can be plugged in with converters from elsewhere (a pub package, FFI):
///
/// ```dart
/// final brotli = AdbCompression(method: AdbCompressionMethod.brotli, decoder: myBrotliDecoder);
/// await adb.sync.readAll('/sdcard/log.txt', compression: brotli);
/// ```
///
/// Compression helps over slow links (Wi-Fi to a TV) with compressible files; APKs, images and video are compressed
/// already. A device that lacks the method, or sync v2, gets an uncompressed transfer instead.
@immutable
final class AdbCompression {
  /// Compression with [method]: [decoder] decodes what the device sends (pulls), [encoder] encodes what is sent
  /// (pushes; without one, pushes are not compressed). Both must support chunked conversion
  /// ([Converter.startChunkedConversion]) and throw [FormatException] for malformed input.
  const AdbCompression({required this.method, required this.decoder, this.encoder});

  /// LZ4, built in: fast, a modest ratio.
  static const AdbCompression lz4 = AdbCompression(
    method: AdbCompressionMethod.lz4,
    decoder: Lz4Frame.decoder,
    encoder: Lz4Frame.encoder,
  );

  /// The method.
  final AdbCompressionMethod method;

  /// Decodes the method's stream format.
  final Converter<List<int>, List<int>> decoder;

  /// Encodes into it, if this side can.
  final Converter<List<int>, List<int>>? encoder;

  @override
  String toString() => 'AdbCompression(${method.name})';
}
