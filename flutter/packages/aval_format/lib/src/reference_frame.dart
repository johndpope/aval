/// Independently decodable reference-rgba-v0 sample codec.
///
/// Dart port of `packages/format/src/reference-frame.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart';
import 'constants.dart';
import 'errors.dart';
import 'model.dart';

const int _maxUint16 = 0xffff;
const int _maxUint32 = 0xffffffff;

class ReferenceFrameInput {
  const ReferenceFrameInput({
    required this.width,
    required this.height,
    required this.frameIndex,
    required this.rgba,
  });

  final int width;
  final int height;
  final int frameIndex;
  final Uint8List rgba;
}

class ReferenceFrameValidationInput {
  const ReferenceFrameValidationInput({
    required this.sample,
    required this.expectedWidth,
    required this.expectedHeight,
    required this.expectedFrameIndex,
    this.options,
  });

  final Uint8List sample;
  final int expectedWidth;
  final int expectedHeight;
  final int expectedFrameIndex;
  final FormatOptions? options;
}

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.referenceFrameInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}

void _assertMagic(Uint8List sample) {
  for (var index = 0; index < referenceFrameMagic.length; index += 1) {
    if (sample[index] != referenceFrameMagic[index]) {
      _fail('reference frame magic must be AVRF', index);
    }
  }
}

int _checkedDimension(int value, String label) {
  if (value < 1 || value > _maxUint16) {
    _fail('$label must be in the uint16 range 1..65535');
  }
  return value;
}

int _checkedFrameIndex(int value, String label) {
  if (value < 0 || value > _maxUint32) {
    _fail('$label must fit uint32');
  }
  return value;
}

int _expectedRgbaLength(int width, int height, int maximum) {
  final pixels = checkedMultiply(width, height, maximum, 'reference pixel count');
  return checkedMultiply(pixels, 4, maximum, 'reference RGBA length');
}

/// Encodes one independently decodable reference-rgba-v0 sample.
Uint8List encodeReferenceFrame(ReferenceFrameInput input) {
  try {
    final width = _checkedDimension(input.width, 'reference width');
    final height = _checkedDimension(input.height, 'reference height');
    final frameIndex = _checkedFrameIndex(input.frameIndex, 'reference frame index');
    final rgbaLength = _expectedRgbaLength(
      width,
      height,
      formatDefaultBudgets.maxSampleBytes - referenceFrameHeaderLength,
    );
    if (input.rgba.length != rgbaLength) {
      _fail('reference RGBA byte length must be exactly $rgbaLength');
    }
    final sampleLength = checkedAdd(
      referenceFrameHeaderLength,
      rgbaLength,
      formatDefaultBudgets.maxSampleBytes,
      'reference sample length',
    );
    Uint8List sample;
    try {
      sample = Uint8List(sampleLength);
    } catch (_) {
      throw FormatError(
        FormatErrorCode.referenceFrameInvalid,
        'reference frame allocation of $sampleLength bytes failed',
      );
    }
    sample.setRange(0, referenceFrameMagic.length, referenceFrameMagic);
    writeUint8(sample, 4, 0, FormatErrorCode.referenceFrameInvalid, 'reference major version');
    writeUint8(sample, 5, 1, FormatErrorCode.referenceFrameInvalid, 'reference minor version');
    writeUint16LE(
      sample,
      6,
      referenceFrameHeaderLength,
      FormatErrorCode.referenceFrameInvalid,
      'reference header length',
    );
    writeUint32LE(sample, 8, 0, FormatErrorCode.referenceFrameInvalid, 'reference flags');
    writeUint16LE(sample, 12, width, FormatErrorCode.referenceFrameInvalid, 'reference width');
    writeUint16LE(sample, 14, height, FormatErrorCode.referenceFrameInvalid, 'reference height');
    writeUint32LE(sample, 16, frameIndex, FormatErrorCode.referenceFrameInvalid, 'reference frame index');
    writeUint32LE(sample, 20, rgbaLength, FormatErrorCode.referenceFrameInvalid, 'reference RGBA length');
    sample.setRange(referenceFrameHeaderLength, referenceFrameHeaderLength + input.rgba.length, input.rgba);
    return sample;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.referenceFrameInvalid, 'reference frame could not be encoded');
  }
}

/// Parses and validates the fixed 24-byte reference-rgba-v0 header.
ReferenceFrameHeader parseReferenceFrameHeader(Uint8List sample, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    requireByteRange(
      sample,
      0,
      referenceFrameHeaderLength,
      FormatErrorCode.referenceFrameInvalid,
      'reference frame header',
    );
    _assertMagic(sample);
    if (readUint8(sample, 4, FormatErrorCode.referenceFrameInvalid, 'reference major version') != 0) {
      _fail('reference frame major version must be zero', 4);
    }
    if (readUint8(sample, 5, FormatErrorCode.referenceFrameInvalid, 'reference minor version') != 1) {
      _fail('reference frame minor version must be one', 5);
    }
    if (readUint16LE(sample, 6, FormatErrorCode.referenceFrameInvalid, 'reference header length') !=
        referenceFrameHeaderLength) {
      _fail('reference frame header length must be $referenceFrameHeaderLength', 6);
    }
    if (readUint32LE(sample, 8, FormatErrorCode.referenceFrameInvalid, 'reference flags') != 0) {
      _fail('reference frame flags must be zero', 8);
    }
    final width = _checkedDimension(
      readUint16LE(sample, 12, FormatErrorCode.referenceFrameInvalid, 'reference width'),
      'reference width',
    );
    final height = _checkedDimension(
      readUint16LE(sample, 14, FormatErrorCode.referenceFrameInvalid, 'reference height'),
      'reference height',
    );
    final frameIndex =
        readUint32LE(sample, 16, FormatErrorCode.referenceFrameInvalid, 'reference frame index');
    final rgbaLength =
        readUint32LE(sample, 20, FormatErrorCode.referenceFrameInvalid, 'reference RGBA length');
    final maximumRgbaLength =
        (budgets.maxSampleBytes - referenceFrameHeaderLength) < 0
            ? 0
            : budgets.maxSampleBytes - referenceFrameHeaderLength;
    final expected = _expectedRgbaLength(width, height, maximumRgbaLength);
    if (rgbaLength != expected) {
      _fail('reference RGBA length must be width × height × 4 ($expected)', 20);
    }
    checkedAdd(referenceFrameHeaderLength, rgbaLength, budgets.maxSampleBytes, 'reference sample length');
    return ReferenceFrameHeader(
      width: width,
      height: height,
      frameIndex: frameIndex,
      rgbaLength: rgbaLength,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.referenceFrameInvalid,
      'reference frame header could not be parsed',
    );
  }
}

/// Validates a complete reference sample and returns only detached byte
/// ranges.
ReferenceFrameDescriptor validateReferenceFrame(ReferenceFrameValidationInput input) {
  try {
    final expectedWidth = _checkedDimension(input.expectedWidth, 'expected reference width');
    final expectedHeight = _checkedDimension(input.expectedHeight, 'expected reference height');
    final expectedFrameIndex =
        _checkedFrameIndex(input.expectedFrameIndex, 'expected reference frame index');
    final header = parseReferenceFrameHeader(input.sample, input.options);
    if (header.width != expectedWidth || header.height != expectedHeight) {
      _fail('reference frame dimensions do not match the rendition', 12);
    }
    if (header.frameIndex != expectedFrameIndex) {
      _fail('reference frame index does not match the access-unit record', 16);
    }
    final expectedSampleLength = checkedAdd(
      referenceFrameHeaderLength,
      header.rgbaLength,
      resolveFormatBudgets(input.options).maxSampleBytes,
      'reference sample length',
    );
    if (input.sample.length != expectedSampleLength) {
      _fail(
        'reference sample length must be exactly $expectedSampleLength bytes',
        input.sample.length < expectedSampleLength ? input.sample.length : expectedSampleLength,
      );
    }
    final rgbaRange = ByteRange(offset: referenceFrameHeaderLength, length: header.rgbaLength);
    return ReferenceFrameDescriptor(
      width: header.width,
      height: header.height,
      frameIndex: header.frameIndex,
      rgbaLength: header.rgbaLength,
      rgbaRange: rgbaRange,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.referenceFrameInvalid, 'reference frame could not be validated');
  }
}
