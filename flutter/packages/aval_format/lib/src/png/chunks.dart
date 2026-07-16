/// Restricted PNG chunk-stream parser: signature, IHDR, optional sRGB, one
/// or more IDAT, and terminal IEND.
///
/// Dart port of `packages/format/src/png/chunks.ts`. All PNG length/CRC
/// fields are big-endian (network byte order), unlike the little-endian
/// helpers in `checked_integer.dart`, so this file implements its own
/// big-endian uint32 reader matching the TS source exactly.
library;

import 'dart:typed_data';

import '../checked_integer.dart';
import '../errors.dart';
import 'crc32.dart';

const List<int> _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const int _maxChunks = 256;

class _IdatRange {
  const _IdatRange(this.offset, this.length);

  final int offset;
  final int length;
}

class ParsedPngChunks {
  const ParsedPngChunks({
    required this.width,
    required this.height,
    required this.zlibBytes,
    required this.chunkCount,
  });

  final int width;
  final int height;
  final Uint8List zlibBytes;
  final int chunkCount;
}

ParsedPngChunks parseRestrictedPngChunks({
  required Uint8List png,
  required int expectedWidth,
  required int expectedHeight,
  required int maximumPngBytes,
}) {
  if (png.length > maximumPngBytes) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'PNG length exceeds the active limit of $maximumPngBytes',
    );
  }
  _requireRange(png, 0, _pngSignature.length, 'PNG signature');
  for (var index = 0; index < _pngSignature.length; index += 1) {
    if (png[index] != _pngSignature[index]) {
      _fail('PNG signature is invalid', index);
    }
  }

  var cursor = _pngSignature.length;
  var chunkCount = 0;
  var width = 0;
  var height = 0;
  var sawIhdr = false;
  var sawSrgb = false;
  var sawIdat = false;
  var ended = false;
  var idatBytes = 0;
  final idatRanges = <_IdatRange>[];

  while (cursor < png.length) {
    chunkCount += 1;
    if (chunkCount > _maxChunks) {
      _fail('PNG must contain at most $_maxChunks chunks', cursor);
    }
    _requireRange(png, cursor, 8, 'PNG chunk header');
    final length = _readUint32Be(png, cursor);
    final dataOffset = checkedAdd(
      cursor,
      8,
      maxSafeInteger,
      'PNG chunk data offset',
    );
    final payloadAndCrcLength = checkedAdd(
      length,
      4,
      maxSafeInteger,
      'PNG chunk payload and CRC length',
    );
    _requireRange(
      png,
      dataOffset,
      payloadAndCrcLength,
      'PNG chunk payload and CRC',
    );
    final dataEnd = checkedAdd(dataOffset, length, png.length, 'PNG chunk data end');
    final chunkEnd = checkedAdd(dataEnd, 4, png.length, 'PNG chunk end');
    final expectedCrc = _readUint32Be(png, dataEnd);
    if (crc32(Uint8List.sublistView(png, cursor + 4, dataEnd)) != expectedCrc) {
      _fail('PNG chunk CRC-32 is invalid', dataEnd);
    }
    final type = _readChunkType(png, cursor + 4);

    if (!sawIhdr) {
      if (type != 'IHDR') _fail('first PNG chunk must be IHDR', cursor + 4);
      if (length != 13) _fail('IHDR payload must contain 13 bytes', cursor);
      width = _readUint32Be(png, dataOffset);
      height = _readUint32Be(png, dataOffset + 4);
      if (width == 0 || height == 0) {
        _fail(
          'PNG dimensions must be positive',
          width == 0 ? dataOffset : dataOffset + 4,
        );
      }
      if (width != expectedWidth || height != expectedHeight) {
        _fail('PNG dimensions do not match the static descriptor', dataOffset);
      }
      if (png[dataOffset + 8] != 8) {
        _fail('PNG bit depth must be 8', dataOffset + 8);
      }
      if (png[dataOffset + 9] != 6) {
        _fail('PNG color type must be RGBA (6)', dataOffset + 9);
      }
      if (png[dataOffset + 10] != 0) {
        _fail('PNG compression method must be zero', dataOffset + 10);
      }
      if (png[dataOffset + 11] != 0) {
        _fail('PNG filter method must be zero', dataOffset + 11);
      }
      if (png[dataOffset + 12] != 0) {
        _fail('PNG must be non-interlaced', dataOffset + 12);
      }
      sawIhdr = true;
    } else if (type == 'sRGB') {
      if (sawSrgb || sawIdat || chunkCount != 2) {
        _fail('sRGB is allowed once immediately after IHDR', cursor + 4);
      }
      if (length != 1 || png[dataOffset] != 0) {
        _fail(
          'sRGB must declare only perceptual rendering intent zero',
          dataOffset,
        );
      }
      sawSrgb = true;
    } else if (type == 'IDAT') {
      if (ended) _fail('IDAT cannot follow IEND', cursor + 4);
      sawIdat = true;
      idatRanges.add(_IdatRange(dataOffset, length));
      idatBytes = checkedAdd(
        idatBytes,
        length,
        maximumPngBytes,
        'combined PNG IDAT bytes',
      );
    } else if (type == 'IEND') {
      if (!sawIdat) _fail('IEND must follow one or more IDAT chunks', cursor + 4);
      if (length != 0) _fail('IEND payload must be empty', cursor);
      if (ended) _fail('PNG must contain exactly one IEND', cursor + 4);
      ended = true;
      if (chunkEnd != png.length) {
        _fail('PNG contains bytes after terminal IEND', chunkEnd);
      }
    } else {
      _fail('PNG contains a chunk outside the restricted profile', cursor + 4);
    }

    cursor = chunkEnd;
    if (ended) break;
  }

  if (!ended) _fail('PNG is missing terminal IEND', cursor);
  if (!sawIdat) _fail('PNG must contain at least one IDAT chunk', cursor);

  Uint8List zlibBytes;
  try {
    zlibBytes = Uint8List(idatBytes);
  } catch (_) {
    _fail('combined PNG IDAT allocation failed for $idatBytes bytes');
  }
  var target = 0;
  for (final range in idatRanges) {
    final rangeEnd = checkedAdd(
      range.offset,
      range.length,
      png.length,
      'PNG IDAT range end',
    );
    zlibBytes.setRange(
      target,
      target + range.length,
      Uint8List.sublistView(png, range.offset, rangeEnd),
    );
    target = checkedAdd(target, range.length, idatBytes, 'PNG IDAT copy end');
  }
  return ParsedPngChunks(
    width: width,
    height: height,
    zlibBytes: zlibBytes,
    chunkCount: chunkCount,
  );
}

void _requireRange(Uint8List bytes, int offset, int length, String label) {
  if (offset < 0 || length < 0 || offset > bytes.length - length) {
    final clamped = offset < 0
        ? 0
        : (offset > bytes.length ? bytes.length : offset);
    _fail('$label is truncated', clamped);
  }
}

int _readUint32Be(Uint8List bytes, int offset) {
  _requireRange(bytes, offset, 4, 'PNG uint32');
  return bytes[offset] * 0x1000000 +
      bytes[offset + 1] * 0x10000 +
      bytes[offset + 2] * 0x100 +
      bytes[offset + 3];
}

String _readChunkType(Uint8List bytes, int offset) {
  _requireRange(bytes, offset, 4, 'PNG chunk type');
  final buffer = StringBuffer();
  for (var index = 0; index < 4; index += 1) {
    final byte = bytes[offset + index];
    if (!((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a))) {
      _fail('PNG chunk type must contain ASCII letters', offset + index);
    }
    buffer.writeCharCode(byte);
  }
  return buffer.toString();
}

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.pngEnvelopeInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}
