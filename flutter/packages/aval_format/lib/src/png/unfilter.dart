/// Noninterlaced 8-bit RGBA scanline unfiltering (PNG filter types 0-4).
///
/// Dart port of `packages/format/src/png/unfilter.ts`. The TS source brands
/// a `PngRgbaLayout` via a module-level `WeakSet` so `unfilterPngRgba` can
/// reject a layout object that was not produced by `derivePngRgbaLayout`.
/// Dart achieves the same guarantee more directly: [PngRgbaLayout] has a
/// private constructor, so only this library can ever construct one, and
/// every [PngRgbaLayout] value that type-checks is therefore genuine — no
/// runtime brand check is needed.
library;

import 'dart:typed_data';

import '../checked_integer.dart';
import '../errors.dart';

const int _bytesPerPixel = 4;
const int _uint32Max = 0xffffffff;

class PngRgbaLayout {
  const PngRgbaLayout._({
    required this.width,
    required this.height,
    required this.rowBytes,
    required this.filteredRowBytes,
    required this.filteredBytes,
    required this.rgbaBytes,
  });

  final int width;
  final int height;
  final int rowBytes;
  final int filteredRowBytes;
  final int filteredBytes;
  final int rgbaBytes;
}

/// Derive all noninterlaced 8-bit RGBA storage using checked arithmetic once.
PngRgbaLayout derivePngRgbaLayout(int widthValue, int heightValue) {
  final width = _dimension(widthValue, 'PNG width');
  final height = _dimension(heightValue, 'PNG height');
  final rowBytes = checkedMultiply(
    width,
    _bytesPerPixel,
    maxSafeInteger,
    'PNG row bytes',
  );
  final filteredRowBytes = checkedAdd(
    rowBytes,
    1,
    maxSafeInteger,
    'PNG filtered row bytes',
  );
  final filteredBytes = checkedMultiply(
    height,
    filteredRowBytes,
    maxSafeInteger,
    'PNG filtered bytes',
  );
  final rgbaBytes = checkedMultiply(
    height,
    rowBytes,
    maxSafeInteger,
    'PNG RGBA bytes',
  );
  return PngRgbaLayout._(
    width: width,
    height: height,
    rowBytes: rowBytes,
    filteredRowBytes: filteredRowBytes,
    filteredBytes: filteredBytes,
    rgbaBytes: rgbaBytes,
  );
}

class PngUnfilterInput {
  const PngUnfilterInput({required this.filtered, required this.layout});

  final Uint8List filtered;
  final PngRgbaLayout layout;
}

/// Reconstruct exact noninterlaced 8-bit RGBA scanlines for filters 0-4.
Uint8List unfilterPngRgba(PngUnfilterInput input) {
  try {
    final layout = input.layout;
    final height = layout.height;
    final rowBytes = layout.rowBytes;
    final filteredRowBytes = layout.filteredRowBytes;
    final filteredBytes = layout.filteredBytes;
    final rgbaBytes = layout.rgbaBytes;
    if (input.filtered.length != filteredBytes) {
      _fail('filtered PNG length does not match its dimensions');
    }
    Uint8List rgba;
    try {
      rgba = Uint8List(rgbaBytes);
    } catch (_) {
      throw FormatError(
        FormatErrorCode.pngScanlineInvalid,
        'PNG RGBA allocation failed for $rgbaBytes bytes',
      );
    }
    for (var row = 0; row < height; row += 1) {
      final sourceRow = row * filteredRowBytes;
      final targetRow = row * rowBytes;
      final filter = input.filtered[sourceRow];
      if (filter > 4) {
        _fail('PNG scanline filter must be from 0 through 4', sourceRow);
      }
      for (var column = 0; column < rowBytes; column += 1) {
        final encoded = input.filtered[sourceRow + 1 + column];
        final left = column >= _bytesPerPixel
            ? rgba[targetRow + column - _bytesPerPixel]
            : 0;
        final up = row > 0 ? rgba[targetRow - rowBytes + column] : 0;
        final upperLeft = row > 0 && column >= _bytesPerPixel
            ? rgba[targetRow - rowBytes + column - _bytesPerPixel]
            : 0;
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
        rgba[targetRow + column] = (encoded + predictor) & 0xff;
      }
    }
    return rgba;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.pngScanlineInvalid,
      'PNG scanlines could not be reconstructed',
    );
  }
}

int _dimension(int value, String label) {
  if (value < 1 || value > _uint32Max) {
    _fail('$label must be from 1 through $_uint32Max');
  }
  return value;
}

int _paeth(int left, int up, int upperLeft) {
  final prediction = left + up - upperLeft;
  final leftDistance = (prediction - left).abs();
  final upDistance = (prediction - up).abs();
  final upperLeftDistance = (prediction - upperLeft).abs();
  if (leftDistance <= upDistance && leftDistance <= upperLeftDistance) {
    return left;
  }
  return upDistance <= upperLeftDistance ? up : upperLeft;
}

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.pngScanlineInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}
