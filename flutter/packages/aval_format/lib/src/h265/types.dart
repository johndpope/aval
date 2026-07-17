/// Public data types for the HEVC (H.265) inspection subsystem.
///
/// Dart port of `packages/format/src/h265/types.ts`.
library;

import 'dart:typed_data';

import 'parameter_sets.dart' show H265ProfileTierLevel;

/// Port of `H265AccessUnitInput` (`src/h265/types.ts:3`).
class H265AccessUnitInput {
  const H265AccessUnitInput({required this.bytes, required this.key});

  final Uint8List bytes;
  final bool key;
}

/// Port of `H265UnitInput` (`src/h265/types.ts:8`).
class H265UnitInput {
  const H265UnitInput({required this.id, required this.accessUnits});

  final String id;
  final List<H265AccessUnitInput> accessUnits;
}

/// Port of `H265FrameRate` (`src/h265/types.ts:13`).
class H265FrameRate {
  const H265FrameRate({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;
}

/// Port of `H265MainProfile` (`src/h265/types.ts:18`).
///
/// `expectedVisibleRect` mirrors the TS `readonly [0, 0, width, height]`
/// tuple as a 4-element `List<int>`.
class H265MainProfile {
  const H265MainProfile({
    required this.codedWidth,
    required this.codedHeight,
    this.expectedVisibleRect,
    required this.frameRate,
    required this.requireBt709LimitedRange,
  });

  final int codedWidth;
  final int codedHeight;
  final List<int>? expectedVisibleRect;
  final H265FrameRate frameRate;
  final bool requireBt709LimitedRange;
}

/// Port of `H265RenditionInspectionInput` (`src/h265/types.ts:31`).
class H265RenditionInspectionInput {
  const H265RenditionInspectionInput({
    required this.profile,
    required this.units,
  });

  final H265MainProfile profile;
  final List<H265UnitInput> units;
}

/// Port of `H265ColorSummary` (`src/h265/types.ts:36`).
class H265ColorSummary {
  const H265ColorSummary({
    required this.fullRange,
    this.colourPrimaries,
    this.transferCharacteristics,
    this.matrixCoefficients,
  });

  final bool fullRange;
  final int? colourPrimaries;
  final int? transferCharacteristics;
  final int? matrixCoefficients;
}

/// Port of `H265CropSummary` (`src/h265/types.ts:43`).
class H265CropSummary {
  const H265CropSummary({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.visibleWidth,
    required this.visibleHeight,
  });

  final int left;
  final int right;
  final int top;
  final int bottom;
  final int visibleWidth;
  final int visibleHeight;
}

/// Port of `H265ParameterSetSummary` (`src/h265/types.ts:52`).
class H265ParameterSetSummary {
  const H265ParameterSetSummary({
    required this.profileTierLevel,
    required this.codec,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.maxNumReorderPics,
    required this.maxDecPicBuffering,
    required this.color,
  });

  final H265ProfileTierLevel profileTierLevel;
  final String codec;
  final int codedWidth;
  final int codedHeight;
  final H265CropSummary crop;

  /// Always `8`.
  final int bitDepth = 8;

  /// Always `"4:2:0"`.
  final String chromaFormat = '4:2:0';
  final int maxNumReorderPics;
  final int maxDecPicBuffering;
  final H265ColorSummary color;
}

/// Random-access picture classification. TS string-literal union
/// `"bla" | "idr" | "cra"` (`src/h265/types.ts:65`).
typedef H265RandomAccessKind = String;

/// Port of `H265AccessUnitSummary` (`src/h265/types.ts:67`).
class H265AccessUnitSummary {
  const H265AccessUnitSummary({
    required this.decodeIndex,
    required this.presentationIndex,
    required this.pictureOrderCount,
    required this.key,
    required this.randomAccess,
    required this.sliceType,
    required this.temporalId,
    required this.referencedPictureOrderCounts,
    required this.nalUnitTypes,
  });

  final int decodeIndex;
  final int presentationIndex;
  final int pictureOrderCount;
  final bool key;

  /// One of `"bla"`, `"idr"`, `"cra"`, or `null` (TS `undefined`).
  final H265RandomAccessKind? randomAccess;

  /// One of `"I"`, `"P"`, `"B"`.
  final String sliceType;
  final int temporalId;
  final List<int> referencedPictureOrderCounts;
  final List<int> nalUnitTypes;
}

/// Port of `H265UnitInspection` (`src/h265/types.ts:79`).
class H265UnitInspection {
  const H265UnitInspection({
    required this.id,
    required this.accessUnits,
    required this.decodeToPresentation,
  });

  final String id;
  final List<H265AccessUnitSummary> accessUnits;
  final List<int> decodeToPresentation;
}

/// Port of `H265RenditionInspection` (`src/h265/types.ts:85`).
class H265RenditionInspection {
  const H265RenditionInspection({
    required this.parameterSet,
    required this.decoderConfig,
    required this.units,
  });

  final H265ParameterSetSummary parameterSet;
  final H265VideoDecoderConfig decoderConfig;
  final List<H265UnitInspection> units;
}

/// The BT.709 color-space block of an [H265VideoDecoderConfig].
///
/// Nested object literal from `H265VideoDecoderConfig.colorSpace`
/// (`src/h265/types.ts:98`). All fields are fixed constants.
class H265DecoderColorSpace {
  const H265DecoderColorSpace();

  /// Always `"bt709"`.
  final String primaries = 'bt709';

  /// Always `"bt709"`.
  final String transfer = 'bt709';

  /// Always `"bt709"`.
  final String matrix = 'bt709';

  /// Always `false`.
  final bool fullRange = false;
}

/// Structural subset of `VideoDecoderConfig` used by the browser adapter.
///
/// Port of `H265VideoDecoderConfig` (`src/h265/types.ts:92`).
class H265VideoDecoderConfig {
  const H265VideoDecoderConfig({
    required this.codec,
    required this.codedWidth,
    required this.codedHeight,
    required this.displayAspectWidth,
    required this.displayAspectHeight,
    required this.colorSpace,
  });

  final String codec;
  final int codedWidth;
  final int codedHeight;
  final int displayAspectWidth;
  final int displayAspectHeight;
  final H265DecoderColorSpace colorSpace;
}
