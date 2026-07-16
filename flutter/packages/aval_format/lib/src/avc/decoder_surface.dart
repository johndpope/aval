/// Browser-decoder coded-surface padding bounds for AVC.
///
/// Dart port of `packages/format/src/avc/decoder-surface.ts`.
library;

// ignore_for_file: constant_identifier_names

import '../errors.dart';

/// Browser-owned decoded-frame allocation may extend the exact SPS coded
/// surface by two macroblocks. Chromium 140 has been observed to expose a
/// 16x16 SPS as a 32x34 coded frame while retaining the exact 16x16 visible
/// rectangle. Reserve two complete macroblocks per axis so those
/// implementation pixels remain bounded without becoming part of the
/// wire/profile geometry.
const int AVC_DECODER_SURFACE_PADDING = 32;

const int _maxSafeInteger = 9007199254740991;

/// Conservative browser-decoder coded-surface bound for one AVC dimension.
int maximumAvcDecoderSurfaceDimension(int dimension) {
  if (dimension < 1) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'AVC decoder surface dimension must be a positive safe integer',
    );
  }
  final aligned = dimension % 16 == 0
      ? dimension
      : _checkedAdd(dimension, 16 - dimension % 16);
  return _checkedAdd(aligned, AVC_DECODER_SURFACE_PADDING);
}

/// Worst-case logical RGBA lease for a decoder surface, including padding.
int maximumAvcDecodedRgbaBytes(int codedWidth, int codedHeight) {
  final width = maximumAvcDecoderSurfaceDimension(codedWidth);
  final height = maximumAvcDecoderSurfaceDimension(codedHeight);
  return _checkedMultiply(_checkedMultiply(width, height), 4);
}

int _checkedAdd(int left, int right) {
  if (left > _maxSafeInteger - right) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'AVC decoder surface size exceeds the safe-integer range',
    );
  }
  return left + right;
}

int _checkedMultiply(int left, int right) {
  if (left != 0 && right > (_maxSafeInteger / left).floor()) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'AVC decoded byte size exceeds the safe-integer range',
    );
  }
  return left * right;
}
