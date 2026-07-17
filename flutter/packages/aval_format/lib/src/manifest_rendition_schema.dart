/// Canvas, frame-rate, and per-codec rendition schema validation.
///
/// Dart port of `packages/format/src/manifest-rendition-schema.ts` (1.0). The
/// per-codec model validates the WebCodecs codec string against the asset's
/// codec family/bit depth via `video/codec_string.dart` and enforces the
/// shared opaque/packed-alpha pane geometry from `video/geometry.dart`.
library;

import 'manifest_validation.dart';
import 'model.dart';
import 'video/codec_string.dart' show isVideoCodecString;
import 'video/geometry.dart' show packedAlphaGutter;

const int _maxPixelAspectTerm = 10000;
const int _maxFrameRate = 60;
const int _maxFrameRateDenominator = 1001;
const int _dimensionMax = 0xffffffff;

Canvas cloneCanvas(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['width', 'height', 'fit', 'pixelAspect', 'colorSpace'], path);
  final width = positiveInteger(input['width'], '$path.width', _dimensionMax);
  final height = positiveInteger(input['height'], '$path.height', _dimensionMax);
  final fit = oneOf(input['fit'], ['contain', 'cover', 'fill', 'none'], '$path.fit');
  final pixelAspectInput = tuple(input['pixelAspect'], 2, '$path.pixelAspect');
  final pixelAspect = [
    positiveInteger(pixelAspectInput[0], '$path.pixelAspect[0]', _maxPixelAspectTerm),
    positiveInteger(pixelAspectInput[1], '$path.pixelAspect[1]', _maxPixelAspectTerm),
  ];
  literal(input['colorSpace'], 'srgb', '$path.colorSpace');
  return Canvas(width: width, height: height, fit: fit, pixelAspect: pixelAspect);
}

Rational cloneFrameRate(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['numerator', 'denominator'], path);
  final numerator = positiveInteger(input['numerator'], '$path.numerator');
  final denominator =
      positiveInteger(input['denominator'], '$path.denominator', _maxFrameRateDenominator);
  if (numerator > denominator * _maxFrameRate) {
    invalid('$path.numerator', 'must not exceed $_maxFrameRate frames per second');
  }
  return Rational(numerator: numerator, denominator: denominator);
}

/// Preserve authored quality order while requiring unique rendition IDs.
List<ProductionRendition> cloneRenditions(
  Object? value,
  Canvas canvas,
  VideoCodec codecFamily,
  VideoLayout layout,
  FormatBudgets budgets,
  String path,
) {
  final inputs = boundedArray(value, path, 1, budgets.maxRenditions);
  final seen = <String>{};
  final renditions = <ProductionRendition>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final rendition =
        _cloneRendition(inputs[index], canvas, codecFamily, layout, '$path[$index]');
    if (seen.contains(rendition.id)) {
      invalid('$path[$index].id', 'duplicates an earlier rendition ID');
    }
    seen.add(rendition.id);
    renditions.add(rendition);
  }
  return renditions;
}

ProductionRendition _cloneRendition(
  Object? value,
  Canvas canvas,
  VideoCodec codecFamily,
  VideoLayout layout,
  String path,
) {
  final input = record(value, path);
  exactKeys(
    input,
    ['id', 'codec', 'bitDepth', 'codedWidth', 'codedHeight', 'alphaLayout', 'bitrate'],
    path,
  );
  final id = identifier(input['id'], '$path.id');
  final bitDepthValue = integerInRange(input['bitDepth'], '$path.bitDepth', 8, 10);
  if (bitDepthValue != 8 && bitDepthValue != 10) {
    invalid('$path.bitDepth', 'must be 8 or 10');
  }
  final bitDepth = bitDepthValue;
  if (codecFamily != 'av1' && bitDepth != 8) {
    invalid('$path.bitDepth', '$codecFamily assets require 8-bit renditions');
  }
  if (!isVideoCodecString(input['codec'], codecFamily, bitDepth)) {
    invalid('$path.codec', 'must be a canonical $codecFamily codec string matching bit depth');
  }
  final codedWidth = positiveInteger(input['codedWidth'], '$path.codedWidth', _dimensionMax);
  final codedHeight = positiveInteger(input['codedHeight'], '$path.codedHeight', _dimensionMax);
  if (codedWidth % 2 != 0 || codedHeight % 2 != 0) {
    invalid(path, '4:2:0 coded dimensions must be even');
  }
  final alphaLayout = _cloneAlphaLayout(
    input['alphaLayout'],
    layout,
    canvas,
    codedWidth,
    codedHeight,
    '$path.alphaLayout',
  );
  final bitrate = _cloneBitrate(input['bitrate'], '$path.bitrate');
  return ProductionRendition(
    id: id,
    codec: input['codec'] as String,
    bitDepth: bitDepth,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    alphaLayout: alphaLayout,
    bitrate: bitrate,
  );
}

AlphaLayout _cloneAlphaLayout(
  Object? value,
  VideoLayout layout,
  Canvas canvas,
  int codedWidth,
  int codedHeight,
  String path,
) {
  final input = record(value, path);
  if (layout == 'opaque') {
    exactKeys(input, ['type', 'colorRect'], path);
    literal(input['type'], 'opaque', '$path.type');
    final colorRect =
        _cloneVisibleColorRect(input['colorRect'], canvas, codedWidth, codedHeight, '$path.colorRect');
    return OpaqueAlphaLayout(colorRect: colorRect);
  }
  exactKeys(input, ['type', 'colorRect', 'alphaRect'], path);
  literal(input['type'], 'stacked', '$path.type');
  final colorRect =
      _cloneVisibleColorRect(input['colorRect'], canvas, codedWidth, codedHeight, '$path.colorRect');
  final alphaRect = _cloneRect(input['alphaRect'], codedWidth, codedHeight, '$path.alphaRect');
  final paneHeight = colorRect.height % 2 == 0 ? colorRect.height : colorRect.height + 1;
  final expectedY = paneHeight + packedAlphaGutter;
  if (alphaRect.x != 0 ||
      alphaRect.y != expectedY ||
      alphaRect.width != colorRect.width ||
      alphaRect.height != colorRect.height) {
    invalid('$path.alphaRect', 'must be a second matching pane after the fixed eight-pixel gutter');
  }
  return StackedAlphaLayout(colorRect: colorRect, alphaRect: alphaRect);
}

Rect _cloneVisibleColorRect(
  Object? value,
  Canvas canvas,
  int codedWidth,
  int codedHeight,
  String path,
) {
  final rect = _cloneRect(value, codedWidth, codedHeight, path);
  if (rect.x != 0 || rect.y != 0) {
    invalid(path, 'visible color rectangle must begin at the decoded surface origin');
  }
  if (rect.width > canvas.width || rect.height > canvas.height) {
    invalid(path, 'visible color rectangle must fit the logical canvas');
  }
  if (BigInt.from(rect.width) * BigInt.from(canvas.height) !=
      BigInt.from(rect.height) * BigInt.from(canvas.width)) {
    invalid(path, 'visible color rectangle must retain the canvas aspect ratio');
  }
  return rect;
}

Bitrate _cloneBitrate(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['average', 'peak'], path);
  final average = positiveInteger(input['average'], '$path.average');
  final peak = positiveInteger(input['peak'], '$path.peak');
  if (average > peak) {
    invalid('$path.average', 'must not exceed peak bitrate');
  }
  return Bitrate(average: average, peak: peak);
}

Rect _cloneRect(Object? value, int surfaceWidth, int surfaceHeight, String path) {
  final input = tuple(value, 4, path);
  final x = nonNegativeInteger(input[0], '$path[0]');
  final y = nonNegativeInteger(input[1], '$path[1]');
  final width = positiveInteger(input[2], '$path[2]');
  final height = positiveInteger(input[3], '$path[3]');
  if (x > surfaceWidth - width || y > surfaceHeight - height) {
    invalid(path, 'must lie inside the coded surface');
  }
  return Rect(x, y, width, height);
}
