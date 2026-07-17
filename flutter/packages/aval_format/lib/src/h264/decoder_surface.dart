/// Browser-decoder coded-surface padding bounds for H264.
///
/// Dart port of `packages/format/src/h264/decoder-surface.ts`.
library;

import '../errors.dart';

/// Browser-owned decoded-frame allocation may extend the exact SPS coded
/// surface by two macroblocks. Chromium 140 has been observed to expose a
/// 16x16 SPS as a 32x34 coded frame while retaining the exact 16x16 visible
/// rectangle. Reserve two complete macroblocks per axis so those
/// implementation pixels remain bounded without becoming part of the
/// wire/profile geometry.
///
/// Port of TS `H264_DECODER_SURFACE_PADDING` (`decoder-surface.ts:10`).
const int h264DecoderSurfacePadding = 32;

const int _maxSafeInteger = 9007199254740991;

/// Conservative browser-decoder coded-surface bound for one H264 dimension.
int maximumH264DecoderSurfaceDimension(int dimension) {
  if (dimension < 1 || dimension > _maxSafeInteger) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'H264 decoder surface dimension must be a positive safe integer',
    );
  }
  final aligned = dimension % 16 == 0
      ? dimension
      : _checkedAdd(dimension, 16 - dimension % 16);
  return _checkedAdd(aligned, h264DecoderSurfacePadding);
}

/// Worst-case logical RGBA lease for a decoder surface, including padding.
int maximumH264DecodedRgbaBytes(int codedWidth, int codedHeight) {
  final width = maximumH264DecoderSurfaceDimension(codedWidth);
  final height = maximumH264DecoderSurfaceDimension(codedHeight);
  return _checkedMultiply(_checkedMultiply(width, height), 4);
}

int _checkedAdd(int left, int right) {
  if (left > _maxSafeInteger - right) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'H264 decoder surface size exceeds the safe-integer range',
    );
  }
  return left + right;
}

int _checkedMultiply(int left, int right) {
  if (left != 0 && right > (_maxSafeInteger / left).floor()) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'H264 decoded byte size exceeds the safe-integer range',
    );
  }
  return left * right;
}
