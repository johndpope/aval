/// Sole rendition-geometry authority: visible/cropped/coded AVC dimensions.
///
/// Dart port of `packages/format/src/avc/rendition-geometry.ts`.
library;

import '../model.dart' show Rect;
import 'failure.dart';
import 'types.dart' show AvcQuantizationPolicy;

const int _packedAlphaGutter = 8;

/// Discriminated by [profile]; `alphaRect` is required for packed-alpha
/// profiles and must be omitted (`null`) for opaque profiles, matching the
/// TS `AvcRenditionGeometryInput` union (`alphaRect?: never` on opaque arms).
class AvcRenditionGeometryInput {
  const AvcRenditionGeometryInput({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.codedWidth,
    required this.codedHeight,
    required this.colorRect,
    required this.profile,
    this.alphaRect,
    this.hasAlphaRectField = false,
  });

  final int canvasWidth;
  final int canvasHeight;
  final int codedWidth;
  final int codedHeight;
  final Rect colorRect;
  final String profile;
  final Rect? alphaRect;

  /// TS distinguishes "alphaRect omitted" from "alphaRect explicitly present
  /// with an invalid value" via `hasOwnProperty`; this flag reproduces that
  /// for opaque profiles that must reject an explicitly supplied field.
  final bool hasAlphaRectField;
}

class AvcVisibleRenditionGeometryInput {
  const AvcVisibleRenditionGeometryInput({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.profile,
    required this.visibleWidth,
    required this.visibleHeight,
  });

  final int canvasWidth;
  final int canvasHeight;
  final String profile;
  final int visibleWidth;
  final int visibleHeight;
}

class AvcRenditionGeometry {
  const AvcRenditionGeometry({
    required this.profile,
    required this.visibleColorRect,
    this.visibleAlphaRect,
    required this.decodedStorageRect,
    required this.codedWidth,
    required this.codedHeight,
    required this.visibleColorArea,
    required this.decodedRgbaBytes,
    required this.codedRgbaBytes,
  });

  final String profile;
  final Rect visibleColorRect;
  final Rect? visibleAlphaRect;
  final Rect decodedStorageRect;
  final int codedWidth;
  final int codedHeight;
  final int visibleColorArea;
  final int decodedRgbaBytes;
  final int codedRgbaBytes;
}

AvcQuantizationPolicy avcQuantizationPolicyForRendition(String profile) {
  switch (profile) {
    case 'avc-annexb-opaque-v0':
    case 'avc-annexb-packed-alpha-v0':
      return 'fixed-qp26-v0';
    case 'avc-annexb-opaque-v1':
    case 'avc-annexb-packed-alpha-v1':
      return 'bounded-qp-v1';
    default:
      avcInvalid(
        'rendition.profile',
        'has an unsupported production AVC profile',
      );
  }
}

/// Validate and derive every visible, cropped-storage, and coded AVC
/// dimension.
///
/// This is the sole rendition-geometry authority shared by schema
/// validation, compilation, worker validation, resource accounting, and
/// presentation.
AvcRenditionGeometry deriveAvcRenditionGeometry(
  AvcRenditionGeometryInput input,
) {
  return deriveAvcRenditionGeometryAtPath(input, 'rendition');
}

/// Derive compiler-ready rectangles and coded dimensions from visible facts.
AvcRenditionGeometry deriveAvcRenditionGeometryFromVisible(
  AvcVisibleRenditionGeometryInput input,
) {
  return deriveAvcRenditionGeometryFromVisibleAtPath(input, 'rendition');
}

/// Package-internal diagnostic-path adapter; not exported by the package.
AvcRenditionGeometry deriveAvcRenditionGeometryAtPath(
  AvcRenditionGeometryInput input,
  String path,
) {
  final codedWidth = _positiveInteger(input.codedWidth, '$path.codedWidth');
  final codedHeight = _positiveInteger(input.codedHeight, '$path.codedHeight');

  final colorPath = '$path.alphaLayout.colorRect';
  final colorRect = _cloneRect(input.colorRect, colorPath);
  final derived = deriveAvcRenditionGeometryFromVisibleAtPath(
    AvcVisibleRenditionGeometryInput(
      canvasWidth: input.canvasWidth,
      canvasHeight: input.canvasHeight,
      profile: input.profile,
      visibleWidth: colorRect.width,
      visibleHeight: colorRect.height,
    ),
    path,
  );
  _requireEqualRect(
    colorRect,
    derived.visibleColorRect,
    colorPath,
    'visible color rectangle does not match the derived geometry',
  );
  if (_isOpaqueProfile(input.profile)) {
    if (input.hasAlphaRectField) {
      avcInvalid(
        '$path.alphaLayout',
        'opaque AVC geometry must not declare an alpha rectangle',
      );
    }
  } else if (_isPackedAlphaProfile(input.profile)) {
    final alphaPath = '$path.alphaLayout.alphaRect';
    if (input.alphaRect == null) {
      avcInvalid(alphaPath, 'must contain exactly four integers');
    }
    final visibleAlphaRect = _cloneRect(input.alphaRect!, alphaPath);
    final expectedAlphaRect = derived.visibleAlphaRect;
    if (expectedAlphaRect == null) {
      avcInvalid(alphaPath, 'packed alpha geometry is missing its derived pane');
    }
    _requireEqualRect(
      visibleAlphaRect,
      expectedAlphaRect,
      alphaPath,
      'packed alpha rectangle must follow the fixed eight-pixel gutter',
    );
  } else {
    avcInvalid('$path.profile', 'has an unsupported production AVC profile');
  }
  if (codedWidth != derived.codedWidth) {
    avcInvalid(
      '$path.codedWidth',
      'must equal the derived coded width ${derived.codedWidth}',
    );
  }
  if (codedHeight != derived.codedHeight) {
    avcInvalid(
      '$path.codedHeight',
      'must equal the derived coded height ${derived.codedHeight}',
    );
  }
  return derived;
}

/// Package-internal diagnostic-path adapter; not exported by the package.
AvcRenditionGeometry deriveAvcRenditionGeometryFromVisibleAtPath(
  AvcVisibleRenditionGeometryInput input,
  String path,
) {
  final canvasWidth = _positiveInteger(input.canvasWidth, 'canvas.width');
  final canvasHeight = _positiveInteger(input.canvasHeight, 'canvas.height');
  final colorPath = '$path.alphaLayout.colorRect';
  final visibleWidth = _positiveInteger(input.visibleWidth, '$colorPath[2]');
  final visibleHeight = _positiveInteger(input.visibleHeight, '$colorPath[3]');
  if (visibleWidth > canvasWidth || visibleHeight > canvasHeight) {
    avcInvalid(colorPath, 'visible color rectangle must fit the logical canvas');
  }
  if (BigInt.from(visibleWidth) * BigInt.from(canvasHeight) !=
      BigInt.from(visibleHeight) * BigInt.from(canvasWidth)) {
    avcInvalid(colorPath, 'visible color rectangle must retain the canvas aspect');
  }
  if (!_isOpaqueProfile(input.profile) && !_isPackedAlphaProfile(input.profile)) {
    avcInvalid('$path.profile', 'has an unsupported production AVC profile');
  }

  final paneWidth = _even(visibleWidth, colorPath);
  final paneHeight = _even(visibleHeight, colorPath);
  final visibleColorRect = Rect(0, 0, visibleWidth, visibleHeight);
  var storageHeight = paneHeight;
  Rect? visibleAlphaRect;
  if (_isPackedAlphaProfile(input.profile)) {
    final alphaPath = '$path.alphaLayout.alphaRect';
    visibleAlphaRect = Rect(
      0,
      _checkedSum(paneHeight, _packedAlphaGutter, alphaPath),
      visibleWidth,
      visibleHeight,
    );
    storageHeight = _checkedSum(
      _checkedProduct(2, paneHeight, alphaPath),
      _packedAlphaGutter,
      alphaPath,
    );
  }
  final codedWidth = _align16(paneWidth, '$path.codedWidth');
  final codedHeight = _align16(storageHeight, '$path.codedHeight');
  final codedPixels = _checkedProduct(codedWidth, codedHeight, '$path.codedWidth');
  final decodedStorageRect = Rect(0, 0, paneWidth, storageHeight);
  final visibleColorArea = _checkedProduct(visibleWidth, visibleHeight, colorPath);
  final decodedRgbaBytes = _checkedProduct(
    _checkedProduct(paneWidth, storageHeight, '$path.decodedStorageRect'),
    4,
    '$path.decodedStorageRect',
  );
  final codedRgbaBytes = _checkedProduct(codedPixels, 4, '$path.codedWidth');

  return AvcRenditionGeometry(
    profile: input.profile,
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

bool _isOpaqueProfile(String profile) =>
    profile == 'avc-annexb-opaque-v0' || profile == 'avc-annexb-opaque-v1';

bool _isPackedAlphaProfile(String profile) =>
    profile == 'avc-annexb-packed-alpha-v0' ||
    profile == 'avc-annexb-packed-alpha-v1';

int _positiveInteger(int value, String path) {
  if (value < 1) {
    avcInvalid(path, 'must be a positive safe integer');
  }
  return value;
}

int _nonNegativeInteger(int value, String path) {
  if (value < 0) {
    avcInvalid(path, 'must be a nonnegative safe integer');
  }
  return value;
}

Rect _cloneRect(Rect value, String path) {
  final x = _nonNegativeInteger(value.x, '$path[0]');
  final y = _nonNegativeInteger(value.y, '$path[1]');
  final width = _positiveInteger(value.width, '$path[2]');
  final height = _positiveInteger(value.height, '$path[3]');
  return Rect(x, y, width, height);
}

int _even(int value, String path) =>
    value % 2 == 0 ? value : _checkedSum(value, 1, path);

int _align16(int value, String path) {
  final remainder = value % 16;
  return remainder == 0 ? value : _checkedSum(value, 16 - remainder, path);
}

const int _maxSafeInteger = 9007199254740991;

int _checkedSum(int left, int right, String path) {
  if (left > _maxSafeInteger - right) {
    avcInvalid(path, 'geometry sum exceeds the safe integer range');
  }
  return left + right;
}

int _checkedProduct(int left, int right, String path) {
  if (left != 0 && right > (_maxSafeInteger / left).floor()) {
    avcInvalid(path, 'geometry product exceeds the safe integer range');
  }
  return left * right;
}

void _requireEqualRect(Rect actual, Rect expected, String path, String message) {
  if (actual.x != expected.x ||
      actual.y != expected.y ||
      actual.width != expected.width ||
      actual.height != expected.height) {
    avcInvalid(path, message);
  }
}
