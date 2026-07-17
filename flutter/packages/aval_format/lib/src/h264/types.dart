/// Shared H264 input/inspection value types.
///
/// Dart port of `packages/format/src/h264/types.ts`.
library;

import 'dart:typed_data';

import '../model.dart' show Rect;
import 'codec.dart' show H264Codec, H264LevelIdc;

/// A single Annex B access unit and its container key assertion.
class H264AccessUnitInput {
  const H264AccessUnitInput({required this.bytes, required this.key});

  final Uint8List bytes;
  final bool key;
}

/// An independently decodable unit. Frame zero must be a closed-GOP IDR.
class H264UnitInput {
  const H264UnitInput({required this.id, required this.accessUnits});

  final String id;
  final List<H264AccessUnitInput> accessUnits;
}

class H264FrameRate {
  const H264FrameRate({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;
}

/// Non-bitstream facts that the compiler requires the High-profile stream to
/// match.
class H264Profile {
  const H264Profile({
    required this.codedWidth,
    required this.codedHeight,
    this.expectedVisibleRect,
    required this.frameRate,
  });

  final int codedWidth;
  final int codedHeight;

  /// TS `expectedVisibleRect?: readonly [0, 0, number, number]`.
  final Rect? expectedVisibleRect;
  final H264FrameRate frameRate;

  /// Always `true` in the TS source (`requireBt709LimitedRange: true`).
  bool get requireBt709LimitedRange => true;
}

class H264RenditionInspectionInput {
  const H264RenditionInspectionInput({
    required this.profile,
    required this.units,
  });

  final H264Profile profile;
  final List<H264UnitInput> units;
}

class H264CropSummary {
  const H264CropSummary({
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

class H264ColorSummary {
  const H264ColorSummary({
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

class H264ParameterSetSummary {
  const H264ParameterSetSummary({
    required this.codec,
    required this.levelIdc,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.maxNumRefFrames,
    required this.maxNumReorderFrames,
    required this.maxDecFrameBuffering,
    required this.hrdPresent,
    required this.fixedFrameRate,
    required this.squareSampleAspect,
    required this.color,
  });

  /// Always `100` in the TS source (`profileIdc: 100`).
  int get profileIdc => 100;
  final H264Codec codec;
  final H264LevelIdc levelIdc;
  final int codedWidth;
  final int codedHeight;
  final H264CropSummary crop;

  /// Always `8` in the TS source (`bitDepth: 8`).
  int get bitDepth => 8;

  /// Always `"4:2:0"` in the TS source (`chromaFormat: "4:2:0"`).
  String get chromaFormat => '4:2:0';
  final int maxNumRefFrames;
  final int maxNumReorderFrames;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final bool fixedFrameRate;
  final bool squareSampleAspect;
  final H264ColorSummary color;
}

/// `"I" | "P" | "B"`.
typedef H264SliceType = String;

class H264AccessUnitSummary {
  const H264AccessUnitSummary({
    required this.decodeIndex,
    required this.presentationIndex,
    required this.pictureOrderCount,
    required this.key,
    required this.idr,
    required this.sliceType,
    required this.sliceCount,
    required this.nalUnitTypes,
  });

  final int decodeIndex;
  final int presentationIndex;
  final int pictureOrderCount;
  final bool key;
  final bool idr;
  final H264SliceType sliceType;
  final int sliceCount;
  final List<int> nalUnitTypes;
}

class H264UnitInspection {
  const H264UnitInspection({
    required this.id,
    required this.accessUnits,
    required this.decodeToPresentation,
  });

  final String id;
  final List<H264AccessUnitSummary> accessUnits;
  final List<int> decodeToPresentation;
}

class H264RenditionInspection {
  const H264RenditionInspection({
    required this.parameterSet,
    required this.macroblocksPerFrame,
    required this.units,
  });

  final H264ParameterSetSummary parameterSet;
  final int macroblocksPerFrame;
  final List<H264UnitInspection> units;
}

/// One raw FFmpeg Annex B stream for an independently encoded unit.
class H264EncoderUnitStreamInput {
  const H264EncoderUnitStreamInput({
    required this.id,
    required this.bytes,
    required this.expectedAccessUnitCount,
  });

  final String id;
  final Uint8List bytes;
  final int expectedAccessUnitCount;
}

class H264EncoderRenditionPreparationInput {
  const H264EncoderRenditionPreparationInput({
    required this.profile,
    required this.units,
  });

  final H264Profile profile;
  final List<H264EncoderUnitStreamInput> units;
}

/// Canonical E0 access units detached from all caller-owned raw streams.
class H264EncoderRenditionPreparation {
  const H264EncoderRenditionPreparation({
    required this.units,
    required this.inspection,
  });

  final List<H264UnitInput> units;
  final H264RenditionInspection inspection;
}
