/// Shared opaque/packed-alpha storage geometry derivation.
///
/// Dart port of `packages/format/src/video/geometry.ts`.
library;

import '../errors.dart';
import '../model.dart' show Rect;
import 'model.dart' show VideoRenditionGeometry, VideoRenditionGeometryInput;

const int packedAlphaGutter = 8;

const int _maxSafeInteger = 9007199254740991;

/// Derive the shared opaque/packed-alpha storage geometry for one codec policy.
///
/// Codec adapters own the encoded-surface alignment; this function owns every
/// cross-codec packing and decoded-byte calculation.
VideoRenditionGeometry deriveVideoRenditionGeometry(
  VideoRenditionGeometryInput input,
) {
  final canvasWidth = _positive(input.canvasWidth, 'canvasWidth');
  final canvasHeight = _positive(input.canvasHeight, 'canvasHeight');
  final visibleWidth = _positive(input.visibleWidth, 'visibleWidth');
  final visibleHeight = _positive(input.visibleHeight, 'visibleHeight');
  if (visibleWidth > canvasWidth || visibleHeight > canvasHeight) {
    _invalid('visible color rectangle must fit the logical canvas');
  }
  if (BigInt.from(visibleWidth) * BigInt.from(canvasHeight) !=
      BigInt.from(visibleHeight) * BigInt.from(canvasWidth)) {
    _invalid('visible color rectangle must retain the canvas aspect ratio');
  }
  if (input.layout != 'opaque' && input.layout != 'packed-alpha') {
    _invalid('layout must be opaque or packed-alpha');
  }
  final widthAlignment =
      _positive(input.storage.widthAlignment, 'storage.widthAlignment');
  final heightAlignment =
      _positive(input.storage.heightAlignment, 'storage.heightAlignment');

  // Every supported production profile is 4:2:0, so each pane is even before
  // codec-specific padding is applied.
  final paneWidth = _align(visibleWidth, 2, 'visibleWidth');
  final paneHeight = _align(visibleHeight, 2, 'visibleHeight');
  final visibleColorRect = Rect(0, 0, visibleWidth, visibleHeight);
  var storageHeight = paneHeight;
  Rect? visibleAlphaRect;
  if (input.layout == 'packed-alpha') {
    visibleAlphaRect = Rect(
      0,
      _add(paneHeight, packedAlphaGutter, 'alpha y'),
      visibleWidth,
      visibleHeight,
    );
    storageHeight = _add(
      _product(2, paneHeight, 'packed height'),
      packedAlphaGutter,
      'packed height',
    );
  }

  final codedWidth = _align(paneWidth, widthAlignment, 'codedWidth');
  final codedHeight = _align(storageHeight, heightAlignment, 'codedHeight');
  final decodedStorageRect = Rect(0, 0, paneWidth, storageHeight);
  final visibleColorArea =
      _product(visibleWidth, visibleHeight, 'visible color area');
  final decodedRgbaBytes = _product(
    _product(paneWidth, storageHeight, 'decoded pixels'),
    4,
    'decoded RGBA bytes',
  );
  final codedRgbaBytes = _product(
    _product(codedWidth, codedHeight, 'coded pixels'),
    4,
    'coded RGBA bytes',
  );

  return VideoRenditionGeometry(
    layout: input.layout,
    visibleColorRect: visibleColorRect,
    visibleAlphaRect: visibleAlphaRect,
    decodedStorageRect: decodedStorageRect,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    visibleColorArea: visibleColorArea,
    decodedRgbaBytes: decodedRgbaBytes,
    codedRgbaBytes: codedRgbaBytes,
  );
}

int _positive(int value, String path) {
  if (value < 1 || value > _maxSafeInteger) {
    _invalid('$path must be a positive safe integer');
  }
  return value;
}

int _align(int value, int alignment, String path) {
  final remainder = value % alignment;
  return remainder == 0 ? value : _add(value, alignment - remainder, path);
}

int _add(int left, int right, String path) {
  if (left > _maxSafeInteger - right) {
    _invalid('$path exceeds the safe integer range');
  }
  return left + right;
}

int _product(int left, int right, String path) {
  if (left != 0 && right > _maxSafeInteger ~/ left) {
    _invalid('$path exceeds the safe integer range');
  }
  return left * right;
}

Never _invalid(String message) {
  throw FormatError(FormatErrorCode.profileInvalid, message);
}
