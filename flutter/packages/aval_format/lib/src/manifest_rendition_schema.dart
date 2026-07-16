/// Canvas, frame-rate, and rendition schema validation.
///
/// Dart port of `packages/format/src/manifest-rendition-schema.ts`.
library;

import 'avc/codec.dart' show AvcCodecV01, AvcLevelLimits, avcLevelLimits, isAvcCodec;
import 'avc/rendition_geometry.dart' show AvcRenditionGeometryInput, deriveAvcRenditionGeometryAtPath;
import 'errors.dart';
import 'manifest_validation.dart';
import 'model.dart';

const int _maxPixelAspectTerm = 10000;
const int _maxFrameRate = 60;
const int _maxFrameRateDenominator = 1001;
const int _pngDimensionMax = 0xffffffff;
const int _referenceDimensionMax = 0xffff;
const int _referenceSampleHeaderBytes = 24;

CanvasV01 cloneCanvas(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['width', 'height', 'fit', 'pixelAspect', 'colorSpace'], path);
  final width = positiveInteger(input['width'], '$path.width', _pngDimensionMax);
  final height = positiveInteger(input['height'], '$path.height', _pngDimensionMax);
  final fit = oneOf(input['fit'], ['contain', 'cover', 'fill', 'none'], '$path.fit');
  final pixelAspectInput = tuple(input['pixelAspect'], 2, '$path.pixelAspect');
  final pixelAspect = [
    positiveInteger(pixelAspectInput[0], '$path.pixelAspect[0]', _maxPixelAspectTerm),
    positiveInteger(pixelAspectInput[1], '$path.pixelAspect[1]', _maxPixelAspectTerm),
  ];
  literal(input['colorSpace'], 'srgb', '$path.colorSpace');
  return CanvasV01(width: width, height: height, fit: fit, pixelAspect: pixelAspect);
}

RationalV01 cloneFrameRate(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['numerator', 'denominator'], path);
  final numerator = positiveInteger(input['numerator'], '$path.numerator');
  final denominator =
      positiveInteger(input['denominator'], '$path.denominator', _maxFrameRateDenominator);
  if (numerator > denominator * _maxFrameRate) {
    invalid('$path.numerator', 'must not exceed $_maxFrameRate frames per second');
  }
  return RationalV01(numerator: numerator, denominator: denominator);
}

List<RenditionV01> cloneRenditions(
  Object? value,
  CanvasV01 canvas,
  RationalV01 frameRate,
  FormatBudgets budgets,
  String path,
) {
  final inputs = boundedArray(value, path, 1, budgets.maxRenditions);
  final renditions = <RenditionV01>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneRendition(inputs[index], canvas, '$path[$index]'),
  ];
  requireIdOrder<RenditionV01>(renditions, (r) => r.id, path);

  String? productionProfile;
  for (var index = 0; index < renditions.length; index += 1) {
    final rendition = renditions[index];
    if (rendition.profile == 'reference-rgba-v0') continue;
    if (rendition.codedWidth % 16 != 0 || rendition.codedHeight % 16 != 0) {
      invalid('$path[$index]', 'AVC coded dimensions must be multiples of 16');
    }
    final level = _avcLevelLimitsForManifest(rendition.codec);
    final widthInMacroblocks = rendition.codedWidth ~/ 16;
    final heightInMacroblocks = rendition.codedHeight ~/ 16;
    if (widthInMacroblocks > level.maximumMacroblockDimension ||
        heightInMacroblocks > level.maximumMacroblockDimension) {
      invalid(
        '$path[$index]',
        'coded width or height exceeds the declared AVC level dimension limit',
      );
    }
    final macroblocksPerFrame = widthInMacroblocks * heightInMacroblocks;
    if (macroblocksPerFrame > level.maximumMacroblocksPerFrame) {
      invalid(
        '$path[$index]',
        'coded dimensions exceed the declared AVC level macroblocks-per-frame limit',
      );
    }
    if (BigInt.from(macroblocksPerFrame) * BigInt.from(frameRate.numerator) >
        BigInt.from(level.maximumMacroblocksPerSecond) * BigInt.from(frameRate.denominator)) {
      invalid(
        '$path[$index]',
        'coded dimensions and frame rate exceed the declared AVC level macroblocks-per-second limit',
      );
    }
    final Rect colorRect;
    final Rect? alphaRect;
    if (rendition is AvcPackedAlphaRenditionV01) {
      colorRect = rendition.colorRect;
      alphaRect = rendition.alphaRect;
    } else {
      colorRect = (rendition as AvcOpaqueRenditionV01).colorRect;
      alphaRect = null;
    }
    deriveAvcRenditionGeometryAtPath(
      AvcRenditionGeometryInput(
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
        codedWidth: rendition.codedWidth,
        codedHeight: rendition.codedHeight,
        colorRect: colorRect,
        profile: rendition.profile,
        alphaRect: alphaRect,
        hasAlphaRectField: alphaRect != null,
      ),
      '$path[$index]',
    );
    if (productionProfile == null) {
      productionProfile = rendition.profile;
    } else if (productionProfile != rendition.profile) {
      throw FormatError(
        FormatErrorCode.profileInvalid,
        'all production AVC renditions must use one profile and version',
        FormatErrorDetails(path: path),
      );
    }
  }
  return renditions;
}

RenditionV01 _cloneRendition(Object? value, CanvasV01 canvas, String path) {
  final input = record(value, path);
  final profile = input['profile'];
  if (profile == 'reference-rgba-v0') {
    exactKeys(
      input,
      ['id', 'profile', 'codec', 'codedWidth', 'codedHeight', 'alphaLayout', 'capabilities'],
      path,
    );
    final common = _cloneRenditionCommon(input, path);
    if (common.codedWidth != canvas.width || common.codedHeight != canvas.height) {
      invalid(path, 'reference rendition dimensions must equal the canvas');
    }
    if (common.codedWidth > _referenceDimensionMax || common.codedHeight > _referenceDimensionMax) {
      invalid(path, 'reference rendition dimensions must fit uint16');
    }
    final referenceSampleBytes = BigInt.from(_referenceSampleHeaderBytes) +
        BigInt.from(common.codedWidth) * BigInt.from(common.codedHeight) * BigInt.from(4);
    if (referenceSampleBytes > BigInt.from(0xffffffff)) {
      invalid(path, 'reference rendition sample length must fit uint32');
    }
    literal(input['codec'], 'aval.reference-rgba', '$path.codec');
    final alpha = record(input['alphaLayout'], '$path.alphaLayout');
    exactKeys(alpha, ['type'], '$path.alphaLayout');
    literal(alpha['type'], 'straight-rgba-v0', '$path.alphaLayout.type');
    tuple(input['capabilities'], 0, '$path.capabilities');
    return ReferenceRgbaRenditionV01(
      id: common.id,
      codedWidth: common.codedWidth,
      codedHeight: common.codedHeight,
    );
  }

  if (profile != 'avc-annexb-opaque-v0' &&
      profile != 'avc-annexb-packed-alpha-v0' &&
      profile != 'avc-annexb-opaque-v1' &&
      profile != 'avc-annexb-packed-alpha-v1') {
    invalid('$path.profile', 'has an unsupported rendition profile');
  }
  exactKeys(
    input,
    ['id', 'profile', 'codec', 'codedWidth', 'codedHeight', 'alphaLayout', 'bitrate', 'capabilities'],
    path,
  );
  final common = _cloneRenditionCommon(input, path);
  final codec = _cloneAvcCodec(input['codec'], '$path.codec');
  final bitrate =
      _cloneBitrate(input['bitrate'], '$path.bitrate', _avcLevelLimitsForManifest(codec).maximumBitrate);
  final capabilitiesInput = tuple(input['capabilities'], 2, '$path.capabilities');
  literal(capabilitiesInput[0], 'webcodecs', '$path.capabilities[0]');
  literal(capabilitiesInput[1], 'webgl2', '$path.capabilities[1]');
  final alpha = record(input['alphaLayout'], '$path.alphaLayout');

  if (profile == 'avc-annexb-opaque-v0' || profile == 'avc-annexb-opaque-v1') {
    exactKeys(alpha, ['type', 'colorRect'], '$path.alphaLayout');
    literal(alpha['type'], 'opaque-v0', '$path.alphaLayout.type');
    final colorRect = _cloneRect(
      alpha['colorRect'],
      common.codedWidth,
      common.codedHeight,
      '$path.alphaLayout.colorRect',
    );
    return AvcOpaqueRenditionV01(
      id: common.id,
      profile: profile as String,
      codec: codec,
      codedWidth: common.codedWidth,
      codedHeight: common.codedHeight,
      colorRect: colorRect,
      bitrate: bitrate,
    );
  }

  exactKeys(alpha, ['type', 'colorRect', 'alphaRect'], '$path.alphaLayout');
  literal(alpha['type'], 'stacked-v0', '$path.alphaLayout.type');
  final colorRect = _cloneRect(
    alpha['colorRect'],
    common.codedWidth,
    common.codedHeight,
    '$path.alphaLayout.colorRect',
  );
  final alphaRect = _cloneRect(
    alpha['alphaRect'],
    common.codedWidth,
    common.codedHeight,
    '$path.alphaLayout.alphaRect',
  );
  return AvcPackedAlphaRenditionV01(
    id: common.id,
    profile: profile as String,
    codec: codec,
    codedWidth: common.codedWidth,
    codedHeight: common.codedHeight,
    colorRect: colorRect,
    alphaRect: alphaRect,
    bitrate: bitrate,
  );
}

class _RenditionCommon {
  const _RenditionCommon(this.id, this.codedWidth, this.codedHeight);

  final String id;
  final int codedWidth;
  final int codedHeight;
}

_RenditionCommon _cloneRenditionCommon(Map<String, Object?> input, String path) {
  final id = identifier(input['id'], '$path.id');
  final codedWidth = positiveInteger(input['codedWidth'], '$path.codedWidth');
  final codedHeight = positiveInteger(input['codedHeight'], '$path.codedHeight');
  return _RenditionCommon(id, codedWidth, codedHeight);
}

BitrateV01 _cloneBitrate(Object? value, String path, int maximum) {
  final input = record(value, path);
  exactKeys(input, ['average', 'peak'], path);
  final average = positiveInteger(input['average'], '$path.average', maximum);
  final peak = positiveInteger(input['peak'], '$path.peak', maximum);
  if (average > peak) {
    invalid('$path.average', 'must not exceed peak bitrate');
  }
  return BitrateV01(average: average, peak: peak);
}

AvcCodecV01 _cloneAvcCodec(Object? value, String path) {
  if (!isAvcCodec(value)) {
    invalid(path, 'must identify a supported Constrained Baseline AVC level');
  }
  return value as String;
}

AvcLevelLimits _avcLevelLimitsForManifest(AvcCodecV01 codec) {
  final levelHex = codec.substring(codec.length - 2);
  return avcLevelLimits(int.parse(levelHex, radix: 16));
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
