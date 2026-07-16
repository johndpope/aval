/// Synthetic in-memory PNG/zlib byte-stream builders shared by the PNG and
/// DEFLATE test suites.
///
/// Dart port of `packages/format/test/png-test-fixture.ts`. The TS source
/// uses `node:zlib`'s `deflateSync` purely to generate real "fixed"/"dynamic"
/// Huffman-coded test vectors (never in production code). This package has
/// zero external dependencies and its production `lib/src/png/*.dart` never
/// touches `dart:io`, but for this *test-only* fixture the equivalent
/// pragmatic choice is `dart:io`'s `ZLibEncoder` (an SDK library, not a pub
/// package, and never linked into the shipped library) — it mirrors the TS
/// test's own use of a native platform compressor solely to build inputs
/// that exercise this package's hand-rolled inflater.
library;

import 'dart:io';
import 'dart:typed_data';

const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// `"stored" | "fixed" | "dynamic"`.
typedef PngCompression = String;

class TestPngInput {
  const TestPngInput({
    required this.width,
    required this.height,
    this.rgba,
    this.filters,
    this.compression = 'stored',
    this.includeSrgb = true,
    this.idatSplits,
    this.zlib,
  });

  final int width;
  final int height;
  final Uint8List? rgba;
  final List<int>? filters;
  final PngCompression compression;
  final bool includeSrgb;
  final List<int>? idatSplits;
  final Uint8List? zlib;
}

Uint8List makeTestPng(TestPngInput input) {
  final rgba = input.rgba ?? patternedRgba(input.width, input.height);
  final filtered = filterRgba(
    rgba,
    input.width,
    input.height,
    input.filters ?? const [0],
  );
  final zlib = input.zlib ?? _compress(filtered, input.compression);
  final ihdr = Uint8List(13);
  writeUint32Be(ihdr, 0, input.width);
  writeUint32Be(ihdr, 4, input.height);
  ihdr.setRange(8, 13, const [8, 6, 0, 0, 0]);
  final chunks = <Uint8List>[chunk('IHDR', ihdr)];
  if (input.includeSrgb) {
    chunks.add(chunk('sRGB', Uint8List.fromList(const [0])));
  }
  final segments = _splitBytes(zlib, input.idatSplits);
  for (final segment in segments) {
    chunks.add(chunk('IDAT', segment));
  }
  chunks.add(chunk('IEND', Uint8List(0)));
  return concatenate([Uint8List.fromList(_pngSignature), ...chunks]);
}

Uint8List makeSizedTestPng(
  int width,
  int height,
  int minimumLength, [
  int marker = 0,
]) {
  final rgba = patternedRgba(width, height);
  if (rgba.isNotEmpty) rgba[0] = marker & 0xff;
  final filtered = filterRgba(rgba, width, height, const [0]);
  final base = makeTestPng(
    TestPngInput(
      width: width,
      height: height,
      rgba: rgba,
      zlib: storedZlib(filtered),
    ),
  );
  final rawExtra = ((minimumLength - base.length) / 5).ceil();
  final extraEmptyBlocks = rawExtra < 0 ? 0 : rawExtra;
  return makeTestPng(
    TestPngInput(
      width: width,
      height: height,
      rgba: rgba,
      zlib: storedZlib(filtered, extraEmptyBlocks),
    ),
  );
}

Uint8List patternedRgba(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var index = 0; index < rgba.length; index += 1) {
    rgba[index] = (index * 73 + (index ~/ 4) * 29 + 17) & 0xff;
  }
  return rgba;
}

Uint8List filterRgba(
  Uint8List rgba,
  int width,
  int height,
  List<int> filters,
) {
  final stride = width * 4;
  if (rgba.length != stride * height) {
    throw StateError('test RGBA length mismatch');
  }
  final result = Uint8List(height * (stride + 1));
  for (var y = 0; y < height; y += 1) {
    final filter = filters[y % filters.length];
    if (filter < 0 || filter > 4) {
      throw StateError('test filter is invalid');
    }
    final target = y * (stride + 1);
    result[target] = filter;
    for (var x = 0; x < stride; x += 1) {
      final raw = rgba[y * stride + x];
      final left = x >= 4 ? rgba[y * stride + x - 4] : 0;
      final up = y > 0 ? rgba[(y - 1) * stride + x] : 0;
      final upperLeft = y > 0 && x >= 4 ? rgba[(y - 1) * stride + x - 4] : 0;
      final int predictor;
      if (filter == 0) {
        predictor = 0;
      } else if (filter == 1) {
        predictor = left;
      } else if (filter == 2) {
        predictor = up;
      } else if (filter == 3) {
        predictor = (left + up) ~/ 2;
      } else {
        predictor = _paeth(left, up, upperLeft);
      }
      result[target + 1 + x] = (raw - predictor) & 0xff;
    }
  }
  return result;
}

Uint8List storedZlib(Uint8List bytes, [int extraEmptyBlocks = 0]) {
  final blockLengths = <int>[];
  var remaining = bytes.length;
  while (remaining > 65535) {
    blockLengths.add(65535);
    remaining -= 65535;
  }
  for (var index = 0; index < extraEmptyBlocks; index += 1) {
    blockLengths.add(0);
  }
  blockLengths.add(remaining);
  final result = Uint8List(2 + blockLengths.length * 5 + bytes.length + 4);
  result.setRange(0, 2, const [0x78, 0x01]);
  var source = 0;
  var target = 2;
  for (var index = 0; index < blockLengths.length; index += 1) {
    final length = blockLengths[index];
    result[target] = index == blockLengths.length - 1 ? 1 : 0;
    result[target + 1] = length & 0xff;
    result[target + 2] = (length >> 8) & 0xff;
    final complement = (~length) & 0xffff;
    result[target + 3] = complement & 0xff;
    result[target + 4] = (complement >> 8) & 0xff;
    target += 5;
    result.setRange(target, target + length, bytes, source);
    source += length;
    target += length;
  }
  writeUint32Be(result, target, testAdler32(bytes));
  return result;
}

Uint8List rebuildPngWithZlib(Uint8List source, Uint8List zlib) {
  final width = readUint32Be(source, 16);
  final height = readUint32Be(source, 20);
  return makeTestPng(TestPngInput(width: width, height: height, zlib: zlib));
}

Uint8List chunk(String type, Uint8List payload) {
  if (type.length != 4) {
    throw StateError('test chunk type must have four bytes');
  }
  final result = Uint8List(payload.length + 12);
  writeUint32Be(result, 0, payload.length);
  for (var index = 0; index < 4; index += 1) {
    result[4 + index] = type.codeUnitAt(index);
  }
  result.setRange(8, 8 + payload.length, payload);
  writeUint32Be(
    result,
    8 + payload.length,
    testCrc32(Uint8List.sublistView(result, 4, 8 + payload.length)),
  );
  return result;
}

Uint8List concatenate(List<Uint8List> parts) {
  final length = parts.fold<int>(0, (total, part) => total + part.length);
  final result = Uint8List(length);
  var offset = 0;
  for (final part in parts) {
    result.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return result;
}

int readUint32Be(Uint8List bytes, int offset) {
  return bytes[offset] * 0x1000000 +
      bytes[offset + 1] * 0x10000 +
      bytes[offset + 2] * 0x100 +
      bytes[offset + 3];
}

void writeUint32Be(Uint8List bytes, int offset, int value) {
  bytes[offset] = (value >> 24) & 0xff;
  bytes[offset + 1] = (value >> 16) & 0xff;
  bytes[offset + 2] = (value >> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
}

int testCrc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int testAdler32(Uint8List bytes) {
  var a = 1;
  var b = 0;
  for (final byte in bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) & 0xffffffff;
}

Uint8List _compress(Uint8List bytes, PngCompression compression) {
  if (compression == 'stored') return storedZlib(bytes);
  final encoder = ZLibEncoder(
    level: compression == 'fixed' ? 6 : 9,
    strategy: compression == 'fixed'
        ? ZLibOption.strategyFixed
        : ZLibOption.strategyDefault,
  );
  return Uint8List.fromList(encoder.convert(bytes));
}

List<Uint8List> _splitBytes(Uint8List bytes, List<int>? requested) {
  if (requested == null) return [bytes];
  final result = <Uint8List>[];
  var offset = 0;
  for (final length in requested) {
    if (length < 0 || offset + length > bytes.length) {
      throw StateError('test IDAT split is invalid');
    }
    result.add(Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
  }
  result.add(Uint8List.sublistView(bytes, offset));
  return result;
}

int _paeth(int left, int up, int upperLeft) {
  final prediction = left + up - upperLeft;
  final leftDistance = (prediction - left).abs();
  final upDistance = (prediction - up).abs();
  final upperLeftDistance = (prediction - upperLeft).abs();
  return leftDistance <= upDistance && leftDistance <= upperLeftDistance
      ? left
      : (upDistance <= upperLeftDistance ? up : upperLeft);
}
