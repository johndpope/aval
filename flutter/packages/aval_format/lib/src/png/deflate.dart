/// Bounded RFC 1951 DEFLATE inflater (stored, fixed, and dynamic blocks).
///
/// Dart port of `packages/format/src/png/deflate.ts`. Preserves every
/// validation rule, error message, and the exact work-limit formula from the
/// TS source.
library;

import 'dart:typed_data';

import '../checked_integer.dart';
import '../errors.dart';
import 'deflate_bit_reader.dart';
import 'deflate_huffman.dart';

const int _maxDistance = 32 * 1024;

const List<int> _codeLengthOrder = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];
const List<int> _lengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const List<int> _lengthExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const List<int> _distanceBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
  193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
  6145, 8193, 12289, 16385, 24577,
];
const List<int> _distanceExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
  6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];

final List<int> _fixedLiteralLengths = _createFixedLiteralLengths();
final List<int> _fixedDistanceLengths = List<int>.filled(32, 5);
final DeflateHuffmanTable _fixedLiteralTable = DeflateHuffmanTable.build(
  _fixedLiteralLengths,
  'fixed literal/length',
);
final DeflateHuffmanTable _fixedDistanceTable = DeflateHuffmanTable.build(
  _fixedDistanceLengths,
  'fixed distance',
);

class DeflateInflateInput {
  const DeflateInflateInput({
    required this.deflate,
    required this.expectedOutputLength,
  });

  final Uint8List deflate;
  final int expectedOutputLength;
}

int calculateDeflateWorkLimit(
  int compressedBytes,
  int expectedInflatedBytes,
) {
  if (compressedBytes < 0 || expectedInflatedBytes < 0) {
    deflateInvalid('DEFLATE work-limit inputs are outside the PNG profile');
  }
  try {
    final bytes = checkedAdd(
      compressedBytes,
      expectedInflatedBytes,
      maxSafeInteger,
      'DEFLATE work bytes',
    );
    return checkedAdd(
      checkedMultiply(bytes, 32, maxSafeInteger, 'DEFLATE work'),
      4096,
      maxSafeInteger,
      'DEFLATE work limit',
    );
  } on FormatError catch (error) {
    deflateInvalid(error.message);
  } catch (_) {
    deflateInvalid('DEFLATE work limit could not be calculated');
  }
}

Uint8List inflateDeflate(DeflateInflateInput input) {
  return inflateDeflateWithLimit(
    input,
    calculateDeflateWorkLimit(
      input.deflate.length,
      input.expectedOutputLength,
    ),
  );
}

/// Package-internal deterministic lower-limit hook used by hostile tests.
Uint8List inflateDeflateWithLimit(DeflateInflateInput input, int workLimit) {
  try {
    if (input.deflate.isEmpty) {
      deflateInvalid('DEFLATE byte length is outside the PNG profile');
    }
    if (input.expectedOutputLength < 0) {
      deflateInvalid('DEFLATE output length is outside the PNG profile');
    }
    final reader = DeflateBitReader(input.deflate, workLimit);
    Uint8List output;
    try {
      output = Uint8List(input.expectedOutputLength);
    } catch (_) {
      throw FormatError(
        FormatErrorCode.pngDeflateInvalid,
        'DEFLATE output allocation failed for '
        '${input.expectedOutputLength} bytes',
      );
    }
    var outputOffset = 0;
    var finalBlock = false;
    while (!finalBlock) {
      finalBlock = reader.readBits(1, 'BFINAL') == 1;
      final blockType = reader.readBits(2, 'BTYPE');
      if (blockType == 0) {
        outputOffset = _inflateStoredBlock(reader, output, outputOffset);
      } else if (blockType == 1) {
        outputOffset = _inflateHuffmanBlock(
          reader,
          output,
          outputOffset,
          _fixedLiteralTable,
          _fixedDistanceTable,
        );
      } else if (blockType == 2) {
        final tables = _readDynamicTables(reader);
        outputOffset = _inflateHuffmanBlock(
          reader,
          output,
          outputOffset,
          tables.literal,
          tables.distance,
        );
      } else {
        deflateInvalid('reserved DEFLATE block type is forbidden');
      }
    }
    reader.finish();
    if (outputOffset != output.length) {
      deflateInvalid('DEFLATE output length does not match the PNG profile');
    }
    return output;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.pngDeflateInvalid,
      'DEFLATE stream could not be decoded',
    );
  }
}

int _inflateStoredBlock(
  DeflateBitReader reader,
  Uint8List output,
  int outputOffset,
) {
  reader.alignToByte('stored block');
  final length = reader.readBits(16, 'stored LEN');
  final complement = reader.readBits(16, 'stored NLEN');
  if (((length ^ 0xffff) & 0xffff) != complement) {
    deflateInvalid('stored DEFLATE LEN/NLEN mismatch');
  }
  if (length > output.length - outputOffset) {
    deflateInvalid('stored DEFLATE block exceeds expected output');
  }
  var offset = outputOffset;
  for (var index = 0; index < length; index += 1) {
    output[offset] = reader.readBits(8, 'stored byte');
    offset += 1;
    reader.copiedOutputByte();
  }
  return offset;
}

int _inflateHuffmanBlock(
  DeflateBitReader reader,
  Uint8List output,
  int initialOutputOffset,
  DeflateHuffmanTable literalTable,
  DeflateHuffmanTable? distanceTable,
) {
  var outputOffset = initialOutputOffset;
  while (true) {
    final symbol = literalTable.decode(reader, 'literal/length symbol');
    if (symbol < 256) {
      if (outputOffset >= output.length) {
        deflateInvalid('literal exceeds expected DEFLATE output');
      }
      output[outputOffset] = symbol;
      outputOffset += 1;
      reader.copiedOutputByte();
      continue;
    }
    if (symbol == 256) return outputOffset;
    if (symbol < 257 || symbol > 285) {
      deflateInvalid('reserved literal/length symbol is forbidden');
    }
    final distance_ = distanceTable;
    if (distance_ == null) {
      deflateInvalid(
        'DEFLATE length symbol requires a nonempty distance tree',
      );
    }
    final lengthIndex = symbol - 257;
    final length = _lengthBase[lengthIndex] +
        reader.readBits(_lengthExtra[lengthIndex], 'length extra bits');
    final distanceSymbol = distance_.decode(reader, 'distance symbol');
    if (distanceSymbol > 29) {
      deflateInvalid('reserved distance symbol is forbidden');
    }
    final distance = _distanceBase[distanceSymbol] +
        reader.readBits(_distanceExtra[distanceSymbol], 'distance extra bits');
    if (distance < 1 || distance > _maxDistance || distance > outputOffset) {
      deflateInvalid('DEFLATE distance exceeds produced history');
    }
    if (length > output.length - outputOffset) {
      deflateInvalid('length/distance copy exceeds expected DEFLATE output');
    }
    for (var index = 0; index < length; index += 1) {
      output[outputOffset] = output[outputOffset - distance];
      outputOffset += 1;
      reader.copiedOutputByte();
    }
  }
}

class _DynamicTables {
  const _DynamicTables(this.literal, this.distance);

  final DeflateHuffmanTable literal;
  final DeflateHuffmanTable? distance;
}

_DynamicTables _readDynamicTables(DeflateBitReader reader) {
  final literalCount = reader.readBits(5, 'HLIT') + 257;
  final distanceCount = reader.readBits(5, 'HDIST') + 1;
  final codeLengthCount = reader.readBits(4, 'HCLEN') + 4;
  final codeLengthLengths = List<int>.filled(19, 0);
  for (var index = 0; index < codeLengthCount; index += 1) {
    codeLengthLengths[_codeLengthOrder[index]] = reader.readBits(
      3,
      'code-length code length',
    );
  }
  final codeLengthTable = DeflateHuffmanTable.build(
    codeLengthLengths,
    'code-length',
  );
  final total = literalCount + distanceCount;
  final lengths = <int>[];
  while (lengths.length < total) {
    final symbol = codeLengthTable.decode(reader, 'code-length symbol');
    if (symbol <= 15) {
      lengths.add(symbol);
      continue;
    }
    int repeated;
    int count;
    if (symbol == 16) {
      if (lengths.isEmpty) {
        deflateInvalid('code-length repeat 16 has no previous value');
      }
      repeated = lengths[lengths.length - 1];
      count = reader.readBits(2, 'repeat-16 count') + 3;
    } else if (symbol == 17) {
      repeated = 0;
      count = reader.readBits(3, 'repeat-17 count') + 3;
    } else if (symbol == 18) {
      repeated = 0;
      count = reader.readBits(7, 'repeat-18 count') + 11;
    } else {
      deflateInvalid('reserved code-length symbol is forbidden');
    }
    if (count > total - lengths.length) {
      deflateInvalid('code-length repeat exceeds the declared tables');
    }
    for (var index = 0; index < count; index += 1) {
      lengths.add(repeated);
    }
  }
  final literalLengths = lengths.sublist(0, literalCount);
  final distanceLengths = lengths.sublist(literalCount);
  if (literalLengths[256] == 0) {
    deflateInvalid('literal/length tree must contain end-of-block symbol 256');
  }
  final d30 = distanceLengths.length > 30 ? distanceLengths[30] : 0;
  final d31 = distanceLengths.length > 31 ? distanceLengths[31] : 0;
  if (d30 != 0 || d31 != 0) {
    deflateInvalid('dynamic tree declares a reserved distance symbol');
  }
  final distance = distanceLengths.every((length) => length == 0)
      ? null
      : DeflateHuffmanTable.build(distanceLengths, 'distance');
  return _DynamicTables(
    DeflateHuffmanTable.build(literalLengths, 'literal/length'),
    distance,
  );
}

List<int> _createFixedLiteralLengths() {
  return List<int>.generate(288, (symbol) {
    if (symbol <= 143) return 8;
    if (symbol <= 255) return 9;
    if (symbol <= 279) return 7;
    return 8;
  });
}
