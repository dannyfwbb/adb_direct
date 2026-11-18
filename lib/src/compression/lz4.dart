// Copyright 2026 The adb_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

import '../protocol/byte_queue.dart';
import 'xxhash32.dart';

/// LZ4, written from the LZ4 block and frame format descriptions (`doc/lz4_Block_format.md`, `doc/lz4_Frame_format.md`
/// in the LZ4 repository).
///
/// Sync v2 uses LZ4 frames (`sendrecv_v2_lz4`); incremental installs send single LZ4 blocks.
abstract final class Lz4 {
  /// Shortest match.
  static const int minMatch = 4;

  /// The last match must start at least this far from the end of a block.
  static const int _matchStartLimit = 12;

  /// The last bytes of a block are always literals.
  static const int _lastLiterals = 5;

  static const int _maxOffset = 0xffff;
  static const int _hashBits = 14;

  /// The largest size [compressBlock] can produce for [length] input bytes.
  static int compressBound(int length) => length + length ~/ 255 + 16;

  /// Compresses [input] (from [start] to [end]) into one LZ4 block, with nothing before it as history. Greedy and fast;
  /// the result decodes with any LZ4 decoder.
  static Uint8List compressBlock(List<int> input, [int start = 0, int? end]) {
    final stop = end ?? input.length;
    final length = stop - start;
    final out = _Output(compressBound(length));
    if (length == 0) {
      out.byte(0);
      return out.bytes();
    }
    final table = Int32List(1 << _hashBits)..fillRange(0, 1 << _hashBits, -1);
    final matchLimit = stop - _matchStartLimit;
    final copyLimit = stop - _lastLiterals;
    var anchor = start;
    var i = start;

    while (i < matchLimit) {
      final sequence = _read32(input, i);
      final hash = _hash(sequence);
      final candidate = table[hash];
      table[hash] = i;
      if (candidate < 0 || i - candidate > _maxOffset || _read32(input, candidate) != sequence) {
        i++;
        continue;
      }
      // Extend backwards over literals that also match, then forwards.
      var matchStart = i;
      var from = candidate;
      while (matchStart > anchor && from > start && input[matchStart - 1] == input[from - 1]) {
        matchStart--;
        from--;
      }
      var matchEnd = i + minMatch;
      var source = candidate + minMatch;
      while (matchEnd < copyLimit && input[matchEnd] == input[source]) {
        matchEnd++;
        source++;
      }
      out.sequence(input, anchor, matchStart, matchStart - from, matchEnd - matchStart);
      // Remember a position inside the match too, for runs.
      if (matchEnd - 2 > matchStart) table[_hash(_read32(input, matchEnd - 2))] = matchEnd - 2;
      i = matchEnd;
      anchor = i;
    }
    out.lastLiterals(input, anchor, stop);
    return out.bytes();
  }

  /// Decompresses one LZ4 block [input] into [output] at [outputStart], where the bytes before [outputStart] (from
  /// [historyStart]) may be referred to by matches. Returns the end of the decoded data in [output].
  ///
  /// Throws [FormatException] for a malformed block, a match before the history, or output past [output]'s end.
  static int decompressBlock(
    List<int> input,
    Uint8List output, {
    int inputStart = 0,
    int? inputEnd,
    int outputStart = 0,
    int historyStart = 0,
  }) {
    final end = inputEnd ?? input.length;
    var i = inputStart;
    var o = outputStart;

    int readLength(int base) {
      var length = base;
      if (base != 15) return length;
      while (true) {
        if (i >= end) throw const FormatException('LZ4 block ends inside a length');
        final b = input[i++];
        length += b;
        if (b != 255) return length;
      }
    }

    while (true) {
      if (i >= end) throw const FormatException('LZ4 block ends before its last literals');
      final token = input[i++];
      final literals = readLength(token >> 4);
      if (literals > end - i) throw const FormatException('LZ4 literals run past the block');
      if (literals > output.length - o) throw const FormatException('LZ4 block decodes past the output');
      output.setRange(o, o + literals, input, i);
      i += literals;
      o += literals;
      if (i == end) return o;
      if (end - i < 2) throw const FormatException('LZ4 block ends inside an offset');
      final offset = input[i] | input[i + 1] << 8;
      i += 2;
      if (offset == 0 || offset > o - historyStart) throw FormatException('LZ4 match offset $offset out of range');
      final matchLength = readLength(token & 15) + minMatch;
      if (matchLength > output.length - o) throw const FormatException('LZ4 block decodes past the output');
      var from = o - offset;
      if (offset >= matchLength) {
        output.setRange(o, o + matchLength, output, from);
        o += matchLength;
      } else {
        // Overlapping: a repeating pattern, copied byte by byte.
        final stop = o + matchLength;
        while (o < stop) {
          output[o++] = output[from++];
        }
      }
    }
  }

  static int _read32(List<int> b, int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24;

  /// Knuth's multiplicative hash of a 4-byte sequence, to [_hashBits] bits.
  static int _hash(int sequence) => _mul32(sequence, 2654435761) >>> (32 - _hashBits);

  /// The low 32 bits of [a] × [b] without products past 2^53.
  static int _mul32(int a, int b) => ((a * (b & 0xffff)) + (((a * (b >>> 16)) & 0xffff) << 16)) & 0xffffffff;
}

/// The LZ4 frame format: a converter that encodes and one that decodes, both usable on streams.
abstract final class Lz4Frame {
  /// The frame magic number.
  static const int magic = 0x184d2204;

  /// Encodes bytes into one LZ4 frame (independent 64 KiB blocks and a content checksum).
  static const Converter<List<int>, List<int>> encoder = _Lz4FrameEncoder();

  /// Decodes one or more concatenated LZ4 frames (skippable frames are skipped); no input at all decodes to nothing.
  /// Malformed input throws [FormatException].
  static const Converter<List<int>, List<int>> decoder = _Lz4FrameDecoder();
}

final class _Lz4FrameEncoder extends Converter<List<int>, List<int>> {
  const _Lz4FrameEncoder();

  @override
  List<int> convert(List<int> input) {
    final output = BytesBuilder(copy: false);
    startChunkedConversion(_CollectingSink(output))
      ..add(input)
      ..close();
    return output.takeBytes();
  }

  @override
  Sink<List<int>> startChunkedConversion(Sink<List<int>> sink) => _Lz4FrameEncoderSink(sink);
}

final class _Lz4FrameEncoderSink implements Sink<List<int>> {
  _Lz4FrameEncoderSink(this._sink);

  static const int _blockSize = 64 * 1024;

  final Sink<List<int>> _sink;
  final Xxh32 _checksum = Xxh32();
  final Uint8List _block = Uint8List(_blockSize);
  int _filled = 0;
  bool _started = false;

  @override
  void add(List<int> data) {
    _start();
    _checksum.add(data);
    var i = 0;
    while (i < data.length) {
      final n = _min(_blockSize - _filled, data.length - i);
      _block.setRange(_filled, _filled + n, data, i);
      _filled += n;
      i += n;
      if (_filled == _blockSize) _flushBlock();
    }
  }

  @override
  void close() {
    _start();
    if (_filled > 0) _flushBlock();
    _sink
      ..add(_le32(0)) // EndMark
      ..add(_le32(_checksum.digest()))
      ..close();
  }

  void _start() {
    if (_started) return;
    _started = true;
    // FLG: version 01, independent blocks, content checksum. BD: 64 KiB blocks.
    const descriptor = [0x64, 0x40];
    _sink.add([..._le32(Lz4Frame.magic), ...descriptor, (Xxh32.of(descriptor) >> 8) & 0xff]);
  }

  void _flushBlock() {
    final compressed = Lz4.compressBlock(_block, 0, _filled);
    if (compressed.length < _filled) {
      _sink
        ..add(_le32(compressed.length))
        ..add(compressed);
    } else {
      _sink
        ..add(_le32(_filled | 0x80000000))
        ..add(Uint8List.fromList(Uint8List.sublistView(_block, 0, _filled)));
    }
    _filled = 0;
  }
}

final class _Lz4FrameDecoder extends Converter<List<int>, List<int>> {
  const _Lz4FrameDecoder();

  @override
  List<int> convert(List<int> input) {
    final output = BytesBuilder(copy: false);
    startChunkedConversion(_CollectingSink(output))
      ..add(input)
      ..close();
    return output.takeBytes();
  }

  @override
  Sink<List<int>> startChunkedConversion(Sink<List<int>> sink) => _Lz4FrameDecoderSink(sink);
}

enum _DecoderState { frameStart, skippable, header, blocks, contentChecksum }

/// Decodes as the input arrives: each block once it is complete.
final class _Lz4FrameDecoderSink implements Sink<List<int>> {
  _Lz4FrameDecoderSink(this._sink);

  static const int _window = 64 * 1024;

  final Sink<List<int>> _sink;
  final ByteQueue _input = ByteQueue();
  _DecoderState _state = _DecoderState.frameStart;

  // The current frame.
  int _skip = 0;
  bool _independent = true;
  bool _blockChecksum = false;
  bool _contentChecksumFlag = false;
  int? _contentSize;
  int _maxBlock = 0;
  Xxh32? _checksum;
  int _produced = 0;

  /// Decoded bytes: the last 64 KiB (for linked blocks) and then the block being decoded.
  Uint8List _buffer = Uint8List(0);
  int _history = 0;

  @override
  void add(List<int> data) {
    _input.add(data);
    _run();
  }

  @override
  void close() {
    _run();
    if (_state != _DecoderState.frameStart || !_input.isEmpty) {
      throw const FormatException('LZ4 data ends inside a frame');
    }
    _sink.close();
  }

  void _run() {
    while (true) {
      final progressed = switch (_state) {
        _DecoderState.frameStart => _frameStart(),
        _DecoderState.skippable => _skippable(),
        _DecoderState.header => _header(),
        _DecoderState.blocks => _block(),
        _DecoderState.contentChecksum => _contentChecksum(),
      };
      if (!progressed) return;
    }
  }

  bool _frameStart() {
    if (_input.length < 8) {
      if (_input.length >= 4 && !_isMagic(_input.peekUint32Le(0))) {
        throw FormatException('Not an LZ4 frame (magic 0x${_input.peekUint32Le(0).toRadixString(16)})');
      }
      return false;
    }
    final magic = _input.peekUint32Le(0);
    if (magic & 0xfffffff0 == 0x184d2a50) {
      _skip = _input.peekUint32Le(4);
      _input.skip(8);
      _state = _DecoderState.skippable;
      return true;
    }
    if (magic != Lz4Frame.magic) throw FormatException('Not an LZ4 frame (magic 0x${magic.toRadixString(16)})');
    _state = _DecoderState.header;
    return true;
  }

  static bool _isMagic(int value) => value == Lz4Frame.magic || value & 0xfffffff0 == 0x184d2a50;

  bool _skippable() {
    final n = _min(_skip, _input.length);
    _input.skip(n);
    _skip -= n;
    if (_skip > 0) return false;
    _state = _DecoderState.frameStart;
    return true;
  }

  bool _header() {
    if (_input.length < 7) return false;
    final flags = _input.byteAt(4);
    final hasSize = flags & 0x08 != 0;
    final hasDictionary = flags & 0x01 != 0;
    final length = 4 + 2 + (hasSize ? 8 : 0) + (hasDictionary ? 4 : 0) + 1;
    if (_input.length < length) return false;
    final header = _input.take(length);
    if (flags >> 6 != 1) throw FormatException('LZ4 frame version ${flags >> 6}');
    if (flags & 0x02 != 0) throw const FormatException('LZ4 frame with reserved flag bits set');
    if (hasDictionary) throw const FormatException('LZ4 frame needs a dictionary');
    final bd = header[5];
    final sizeId = (bd >> 4) & 7;
    if (bd & 0x8f != 0 || sizeId < 4) throw FormatException('LZ4 frame block descriptor 0x${bd.toRadixString(16)}');
    final descriptor = Uint8List.sublistView(header, 4, length - 1);
    if ((Xxh32.of(descriptor) >> 8) & 0xff != header[length - 1]) {
      throw const FormatException('LZ4 frame header checksum mismatch');
    }
    _independent = flags & 0x20 != 0;
    _blockChecksum = flags & 0x10 != 0;
    _contentChecksumFlag = flags & 0x04 != 0;
    _contentSize = hasSize ? ByteData.sublistView(header, 6, 14).getUint64(0, Endian.little) : null;
    _maxBlock = 1 << (8 + 2 * sizeId);
    _checksum = _contentChecksumFlag ? Xxh32() : null;
    _produced = 0;
    final size = _window + _maxBlock;
    if (_buffer.length != size) _buffer = Uint8List(size);
    _history = 0;
    _state = _DecoderState.blocks;
    return true;
  }

  bool _block() {
    if (_input.length < 4) return false;
    final word = _input.peekUint32Le(0);
    if (word == 0) {
      _input.skip(4);
      if (_contentSize case final size? when size != _produced) {
        throw FormatException('LZ4 frame announced $size bytes, decoded $_produced');
      }
      _state = _contentChecksumFlag ? _DecoderState.contentChecksum : _DecoderState.frameStart;
      return true;
    }
    final stored = word & 0x80000000 != 0;
    final size = word & 0x7fffffff;
    if (size > _maxBlock) throw FormatException('LZ4 block of $size bytes in a frame of $_maxBlock-byte blocks');
    final total = 4 + size + (_blockChecksum ? 4 : 0);
    if (_input.length < total) return false;
    _input.skip(4);
    final data = _input.take(size);
    if (_blockChecksum && ByteData.sublistView(_input.take(4)).getUint32(0, Endian.little) != Xxh32.of(data)) {
      throw const FormatException('LZ4 block checksum mismatch');
    }

    final int end;
    if (stored) {
      _buffer.setRange(_history, _history + size, data);
      end = _history + size;
    } else {
      end = Lz4.decompressBlock(data, _buffer, outputStart: _history, historyStart: _independent ? _history : 0);
    }
    final decoded = Uint8List.fromList(Uint8List.sublistView(_buffer, _history, end));
    _checksum?.add(decoded);
    _produced += decoded.length;
    _sink.add(decoded);
    _keepHistory(end);
    return true;
  }

  /// Keeps the last 64 KiB of output at the front of the buffer for the next linked block.
  void _keepHistory(int end) {
    if (_independent) return;
    final keep = _min(end, _window);
    _buffer.setRange(0, keep, _buffer, end - keep);
    _history = keep;
  }

  bool _contentChecksum() {
    if (_input.length < 4) return false;
    final expected = _input.peekUint32Le(0);
    _input.skip(4);
    if (expected != _checksum!.digest()) throw const FormatException('LZ4 content checksum mismatch');
    _state = _DecoderState.frameStart;
    return true;
  }
}

final class _CollectingSink implements Sink<List<int>> {
  _CollectingSink(this._builder);

  final BytesBuilder _builder;

  @override
  void add(List<int> data) => _builder.add(data);

  @override
  void close() {}
}

/// Builds an LZ4 block.
final class _Output {
  _Output(int capacity) : _bytes = Uint8List(capacity);

  final Uint8List _bytes;
  int _length = 0;

  void byte(int value) => _bytes[_length++] = value;

  void _extraLength(int length) {
    var rest = length - 15;
    while (rest >= 255) {
      byte(255);
      rest -= 255;
    }
    byte(rest);
  }

  void _literals(List<int> input, int from, int to) {
    _bytes.setRange(_length, _length + to - from, input, from);
    _length += to - from;
  }

  /// Literals from [from] to [to], then a match of [length] bytes [offset] back.
  void sequence(List<int> input, int from, int to, int offset, int length) {
    final literals = to - from;
    final matchCode = length - Lz4.minMatch;
    byte((literals >= 15 ? 15 : literals) << 4 | (matchCode >= 15 ? 15 : matchCode));
    if (literals >= 15) _extraLength(literals);
    _literals(input, from, to);
    byte(offset & 0xff);
    byte(offset >> 8);
    if (matchCode >= 15) _extraLength(matchCode);
  }

  void lastLiterals(List<int> input, int from, int to) {
    final literals = to - from;
    byte((literals >= 15 ? 15 : literals) << 4);
    if (literals >= 15) _extraLength(literals);
    _literals(input, from, to);
  }

  Uint8List bytes() => Uint8List.sublistView(_bytes, 0, _length);
}

Uint8List _le32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

int _min(int a, int b) => a < b ? a : b;
