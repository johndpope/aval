/// Shared AVC input/inspection value types.
///
/// Dart port of `packages/format/src/avc/types.ts`.
library;

import 'dart:typed_data';

import '../model.dart' show Rect;
import 'codec.dart' show AvcLevelIdc;

/// A single Annex B access unit and its container key assertion.
class AvcAccessUnitInput {
  const AvcAccessUnitInput({required this.bytes, required this.key});

  final Uint8List bytes;
  final bool key;
}

/// An independently decodable unit. Frame zero must be a closed-GOP IDR.
class AvcUnitInput {
  const AvcUnitInput({required this.id, required this.accessUnits});

  final String id;
  final List<AvcAccessUnitInput> accessUnits;
}

class AvcFrameRate {
  const AvcFrameRate({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;
}

/// `"fixed-qp26-v0" | "bounded-qp-v1"`.
typedef AvcQuantizationPolicy = String;

/// The non-bitstream limits supplied by the compiler profile. `cpbBufferBits`
/// is the exact FFmpeg VBV buffer setting; when HRD is present it is also
/// checked against the value signalled by the SPS.
class AvcConstrainedBaselineProfile {
  const AvcConstrainedBaselineProfile({
    required this.codedWidth,
    required this.codedHeight,
    this.expectedDecodedStorageRect,
    required this.frameRate,
    required this.averageBitrate,
    required this.peakBitrate,
    required this.cpbBufferBits,
    required this.quantizationPolicy,
  });

  final int codedWidth;
  final int codedHeight;

  /// Exact decoded-picture crop; omitted only for full-coded M5 compatibility.
  final Rect? expectedDecodedStorageRect;
  final AvcFrameRate frameRate;
  final int averageBitrate;
  final int peakBitrate;
  final int cpbBufferBits;

  /// Always `true` in the TS source (`requireBt709LimitedRange: true`).
  bool get requireBt709LimitedRange => true;
  final AvcQuantizationPolicy quantizationPolicy;
}

class AvcRenditionInspectionInput {
  const AvcRenditionInspectionInput({
    required this.profile,
    required this.units,
  });

  final AvcConstrainedBaselineProfile profile;
  final List<AvcUnitInput> units;
}

class AvcCropSummary {
  const AvcCropSummary({
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

class AvcColorSummary {
  const AvcColorSummary({
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

class AvcParameterSetSummary {
  const AvcParameterSetSummary({
    required this.constraintSet2,
    required this.levelIdc,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.maxDecFrameBuffering,
    required this.hrdPresent,
    required this.fixedFrameRate,
    required this.squareSampleAspect,
    required this.color,
  });

  /// Always `66` in the TS source (`profileIdc: 66`).
  int get profileIdc => 66;
  final bool constraintSet2;
  final AvcLevelIdc levelIdc;
  final int codedWidth;
  final int codedHeight;
  final AvcCropSummary crop;

  /// Always `1` in the TS source (`maxNumRefFrames: 1`).
  int get maxNumRefFrames => 1;

  /// Always `0` in the TS source (`maxNumReorderFrames: 0`).
  int get maxNumReorderFrames => 0;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final bool fixedFrameRate;
  final bool squareSampleAspect;
  final AvcColorSummary color;
}

/// `"I" | "P"`.
typedef AvcSliceType = String;

class AvcAccessUnitSummary {
  const AvcAccessUnitSummary({
    required this.frameIndex,
    required this.key,
    required this.idr,
    required this.sliceType,
    required this.sliceCount,
    required this.nalUnitTypes,
  });

  final int frameIndex;
  final bool key;
  final bool idr;
  final AvcSliceType sliceType;
  final int sliceCount;
  final List<int> nalUnitTypes;
}

class AvcUnitInspection {
  const AvcUnitInspection({required this.id, required this.frames});

  final String id;
  final List<AvcAccessUnitSummary> frames;
}

class AvcRenditionInspection {
  const AvcRenditionInspection({
    required this.parameterSet,
    required this.macroblocksPerFrame,
    required this.units,
  });

  final AvcParameterSetSummary parameterSet;
  final int macroblocksPerFrame;
  final List<AvcUnitInspection> units;
}

/// One sequential worker sample inspected before it reaches a decoder.
class AvcIncrementalAccessUnitInput extends AvcAccessUnitInput {
  const AvcIncrementalAccessUnitInput({
    required super.bytes,
    required super.key,
    required this.unitId,
    required this.unitInstance,
    required this.unitFrame,
    required this.unitFrameCount,
  });

  final String unitId;
  final int unitInstance;
  final int unitFrame;
  final int unitFrameCount;
}

/// `"key" | "delta"`.
typedef AvcChunkType = String;

/// Immutable, byte-view-free result used to derive the decoder chunk type.
class AvcIncrementalAccessUnitInspection {
  const AvcIncrementalAccessUnitInspection({
    required this.unitId,
    required this.unitInstance,
    required this.unitFrame,
    required this.unitFrameCount,
    required this.unitComplete,
    required this.chunkType,
    required this.accessUnit,
  });

  final String unitId;
  final int unitInstance;
  final int unitFrame;
  final int unitFrameCount;
  final bool unitComplete;
  final AvcChunkType chunkType;
  final AvcAccessUnitSummary accessUnit;
}

/// One raw FFmpeg Annex B stream for an independently encoded unit.
class AvcEncoderUnitStreamInput {
  const AvcEncoderUnitStreamInput({
    required this.id,
    required this.bytes,
    required this.expectedAccessUnitCount,
  });

  final String id;
  final Uint8List bytes;
  final int expectedAccessUnitCount;
}

class AvcEncoderRenditionPreparationInput {
  const AvcEncoderRenditionPreparationInput({
    required this.profile,
    required this.units,
  });

  final AvcConstrainedBaselineProfile profile;
  final List<AvcEncoderUnitStreamInput> units;
}

class AvcUnitCanonicalization {
  const AvcUnitCanonicalization({
    required this.unitId,
    required this.constraintSet2Canonicalized,
  });

  final String unitId;
  final bool constraintSet2Canonicalized;
}

/// Canonical E0 access units detached from all caller-owned raw streams.
class AvcEncoderRenditionPreparation {
  const AvcEncoderRenditionPreparation({
    required this.units,
    required this.inspection,
    required this.canonicalizations,
  });

  final List<AvcUnitInput> units;
  final AvcRenditionInspection inspection;
  final List<AvcUnitCanonicalization> canonicalizations;
}
