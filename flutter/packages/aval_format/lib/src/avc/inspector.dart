/// Inspects every access unit in an independently decodable AVC rendition.
///
/// This is intentionally a syntax/dependency verifier, not a decoder. It
/// accepts only the versioned production Constrained Baseline subset and
/// returns a deeply immutable scalar summary; no caller-owned byte views
/// escape.
///
/// Dart port of `packages/format/src/avc/inspector.ts`.
library;

import '../checked_integer.dart' show maxSafeInteger;
import '../constants.dart' show formatDefaultBudgets, identifierPattern;
import '../errors.dart';
import '../model.dart' show Rect;
import 'annex_b.dart';
import 'bit_reader.dart';
import 'codec.dart' show avcCodecForLevel, avcLevelLimits;
import 'failure.dart';
import 'parameter_sets.dart';
import 'slice_header.dart';
import 'types.dart';

/// `"strict" | "encoder-candidate"`.
typedef AvcCompatibilityPolicy = String;

class AvcParameterSetState {
  const AvcParameterSetState({required this.sps, required this.pps});

  final ParsedSps sps;
  final ParsedPps pps;
}

/// Mutable picture-order tracking state threaded through one unit's frames.
class AvcPictureOrderState {
  AvcPictureOrderState({
    this.previousFrameNum = 0,
    this.frameNumOffset = 0,
    this.previousPoc = -1,
    this.previousPocMsb = 0,
    this.previousPocLsb = 0,
  });

  int previousFrameNum;
  int frameNumOffset;
  int previousPoc;
  int previousPocMsb;
  int previousPocLsb;
}

class AvcAccessUnitStateResult {
  const AvcAccessUnitStateResult({
    required this.summary,
    required this.parameterSets,
  });

  final AvcAccessUnitSummary summary;
  final AvcParameterSetState parameterSets;
}

/// AVC level `maximumCpbBits`, keyed by `level_idc`. `codec.dart`'s
/// `AvcLevelLimits` does not expose this TS field (see
/// `packages/format/src/avc/codec.ts` `LEVEL_ROWS` column 6), so it is
/// reproduced here from the same source table since this is the only AVC
/// consumer that needs it.
const Map<int, int> _maximumCpbBitsByLevel = {
  10: 175000,
  11: 500000,
  12: 1000000,
  13: 2000000,
  20: 2000000,
  21: 4000000,
  22: 4000000,
  30: 10000000,
  31: 14000000,
  32: 20000000,
  40: 25000000,
  41: 62500000,
  42: 62500000,
  50: 135000000,
  51: 240000000,
  52: 240000000,
  60: 240000000,
  61: 480000000,
  62: 800000000,
};

/// Inspects every access unit in an independently decodable rendition.
AvcRenditionInspection inspectAvcAnnexBRendition(
  AvcRenditionInspectionInput input,
) =>
    _inspectRendition(input, 'strict');

/// Proves the complete production subset while tolerating libx264's C0
/// compatibility byte solely as an encoder-normalization candidate.
AvcRenditionInspection inspectAvcAnnexBEncoderCandidateRendition(
  AvcRenditionInspectionInput input,
) =>
    _inspectRendition(input, 'encoder-candidate');

AvcRenditionInspection _inspectRendition(
  AvcRenditionInspectionInput input,
  AvcCompatibilityPolicy compatibilityPolicy,
) {
  try {
    final profile = cloneAvcProfile(input.profile);
    requireAvc(input.units.isNotEmpty, 'units', 'at least one unit is required');
    requireAvc(
      input.units.length <= formatDefaultBudgets.maxUnits,
      'units',
      'unit count exceeds the format budget',
    );

    final seenUnitIds = <String>{};
    AvcParameterSetState? stableParameterSets;
    int? macroblocksPerFrame;
    var totalFrames = 0;
    final units = <AvcUnitInspection>[];

    for (var unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
      final unit = input.units[unitIndex];
      final unitPath = 'units[$unitIndex]';
      requireAvc(
        identifierPattern.hasMatch(unit.id),
        '$unitPath.id',
        'unit id is invalid',
      );
      requireAvc(
        !seenUnitIds.contains(unit.id),
        '$unitPath.id',
        'unit id is duplicated',
      );
      seenUnitIds.add(unit.id);
      requireAvc(
        unit.accessUnits.isNotEmpty,
        '$unitPath.accessUnits',
        'unit must contain at least one access unit',
      );
      totalFrames += unit.accessUnits.length;
      requireAvc(
        totalFrames <= formatDefaultBudgets.maxTotalUnitFrames,
        '$unitPath.accessUnits',
        'total frame count exceeds the format budget',
      );

      final orderState = createAvcPictureOrderState();
      final frames = <AvcAccessUnitSummary>[];
      var activeParameterSets = stableParameterSets;

      for (
        var frameIndex = 0;
        frameIndex < unit.accessUnits.length;
        frameIndex += 1
      ) {
        final accessUnit = unit.accessUnits[frameIndex];
        final framePath = '$unitPath.accessUnits[$frameIndex]';
        validateAvcAccessUnitInput(accessUnit, framePath);
        final result = inspectAvcAccessUnitStatefully(
          accessUnit,
          frameIndex,
          framePath,
          activeParameterSets,
          stableParameterSets,
          profile,
          orderState,
          macroblocksPerFrame,
          compatibilityPolicy,
        );
        activeParameterSets = result.parameterSets;
        if (stableParameterSets == null) {
          stableParameterSets = result.parameterSets;
          macroblocksPerFrame = validateAvcSpsAgainstProfile(
            stableParameterSets.sps,
            profile,
            '$framePath.sps',
            compatibilityPolicy,
          );
        }
        frames.add(result.summary);
      }

      units.add(
        AvcUnitInspection(id: unit.id, frames: List.unmodifiable(frames)),
      );
    }

    requireAvc(
      stableParameterSets != null && macroblocksPerFrame != null,
      'units',
      'no AVC parameter sets were found',
    );
    final resolvedStableParameterSets = stableParameterSets!;
    final resolvedMacroblocksPerFrame = macroblocksPerFrame!;
    final parameterSet =
        createAvcParameterSetSummary(resolvedStableParameterSets.sps);
    return AvcRenditionInspection(
      parameterSet: parameterSet,
      macroblocksPerFrame: resolvedMacroblocksPerFrame,
      units: List.unmodifiable(units),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.profileInvalid, 'AVC inspection failed');
  }
}

AvcConstrainedBaselineProfile cloneAvcProfile(
  AvcConstrainedBaselineProfile profile,
) {
  _positiveInteger(profile.codedWidth, 'profile.codedWidth');
  _positiveInteger(profile.codedHeight, 'profile.codedHeight');
  final expectedDecodedStorageRect = _cloneExpectedDecodedStorageRect(
    profile.expectedDecodedStorageRect,
    profile.codedWidth,
    profile.codedHeight,
  );
  _positiveInteger(profile.frameRate.numerator, 'profile.frameRate.numerator');
  _positiveInteger(
    profile.frameRate.denominator,
    'profile.frameRate.denominator',
  );
  _positiveInteger(profile.averageBitrate, 'profile.averageBitrate');
  _positiveInteger(profile.peakBitrate, 'profile.peakBitrate');
  _positiveInteger(profile.cpbBufferBits, 'profile.cpbBufferBits');
  requireAvc(
    profile.averageBitrate <= profile.peakBitrate,
    'profile.averageBitrate',
    'average bitrate must not exceed peak bitrate',
  );
  requireAvc(
    profile.cpbBufferBits == profile.peakBitrate,
    'profile.cpbBufferBits',
    'CPB buffer bits must equal peak bitrate',
  );
  requireAvc(
    profile.requireBt709LimitedRange == true,
    'profile.requireBt709LimitedRange',
    'the production AVC profile requires BT.709 limited range',
  );
  requireAvc(
    profile.quantizationPolicy == 'fixed-qp26-v0' ||
        profile.quantizationPolicy == 'bounded-qp-v1',
    'profile.quantizationPolicy',
    'must identify a supported AVC quantization policy',
  );
  return AvcConstrainedBaselineProfile(
    codedWidth: profile.codedWidth,
    codedHeight: profile.codedHeight,
    expectedDecodedStorageRect: expectedDecodedStorageRect,
    frameRate: AvcFrameRate(
      numerator: profile.frameRate.numerator,
      denominator: profile.frameRate.denominator,
    ),
    averageBitrate: profile.averageBitrate,
    peakBitrate: profile.peakBitrate,
    cpbBufferBits: profile.cpbBufferBits,
    quantizationPolicy: profile.quantizationPolicy,
  );
}

Rect _cloneExpectedDecodedStorageRect(
  Rect? value,
  int codedWidth,
  int codedHeight,
) {
  if (value == null) {
    return Rect(0, 0, codedWidth, codedHeight);
  }
  requireAvc(
    value.x == 0 && value.y == 0,
    'profile.expectedDecodedStorageRect',
    'expected decoded storage rectangle must begin at the coded origin',
  );
  _positiveIntegerMax(
    value.width,
    'profile.expectedDecodedStorageRect[2]',
    codedWidth,
  );
  _positiveIntegerMax(
    value.height,
    'profile.expectedDecodedStorageRect[3]',
    codedHeight,
  );
  requireAvc(
    value.width % 2 == 0 && value.height % 2 == 0,
    'profile.expectedDecodedStorageRect',
    'expected decoded storage dimensions must be even for yuv420p',
  );
  requireAvc(
    (codedWidth - value.width) % 2 == 0 &&
        (codedHeight - value.height) % 2 == 0,
    'profile.expectedDecodedStorageRect',
    'expected decoded storage crop must use 4:2:0 crop units',
  );
  return Rect(0, 0, value.width, value.height);
}

void _positiveInteger(int value, String path) {
  requireAvc(
    value > 0 && value <= maxSafeInteger,
    path,
    'must be a positive safe integer',
  );
}

void _positiveIntegerMax(int value, String path, int maximum) {
  requireAvc(
    value > 0 && value <= maximum,
    path,
    'must be a positive safe integer no greater than $maximum',
  );
}

void validateAvcAccessUnitInput(AvcAccessUnitInput accessUnit, String path) {
  requireAvc(
    accessUnit.bytes.length <= formatDefaultBudgets.maxSampleBytes,
    '$path.bytes',
    'access unit exceeds the sample budget',
  );
}

AvcAccessUnitStateResult inspectAvcAccessUnitStatefully(
  AvcAccessUnitInput accessUnit,
  int frameIndex,
  String path,
  AvcParameterSetState? activeParameterSets,
  AvcParameterSetState? stableParameterSets,
  AvcConstrainedBaselineProfile profile,
  AvcPictureOrderState orderState,
  int? knownMacroblocksPerFrame, [
  AvcCompatibilityPolicy compatibilityPolicy = 'strict',
]) {
  final nals = splitAnnexBAccessUnit(accessUnit.bytes, '$path.bytes');
  final nalTypes = List<int>.unmodifiable(nals.map((nal) => nal.type));
  ParsedSps? parsedSps;
  ParsedPps? parsedPps;
  int? audPrimaryPicType;
  final vcl = <AnnexBNalUnit>[];
  var reachedVcl = false;

  for (var index = 0; index < nals.length; index += 1) {
    final nal = nals[index];
    final nalPath = '$path.nals[$index]';
    switch (nal.type) {
      case AVC_NAL_TYPE_AUD:
        {
          requireAvc(
            index == 0 && audPrimaryPicType == null,
            nalPath,
            'AUD must appear once, before every other NAL',
            nal.offset,
          );
          audPrimaryPicType = _parseAud(nal, nalPath);
          break;
        }
      case AVC_NAL_TYPE_SPS:
        {
          requireAvc(
            !reachedVcl && parsedSps == null && parsedPps == null,
            nalPath,
            'SPS must appear once before PPS and VCL',
            nal.offset,
          );
          parsedSps = parseSps(nal, nalPath, compatibilityPolicy);
          break;
        }
      case AVC_NAL_TYPE_PPS:
        {
          requireAvc(
            !reachedVcl && parsedPps == null && parsedSps != null,
            nalPath,
            'PPS must appear once after SPS and before VCL',
            nal.offset,
          );
          final currentSps = parsedSps!;
          final parsedPpsValue =
              parsePps(nal, nalPath, profile.quantizationPolicy);
          requireAvc(
            parsedPpsValue.spsId == currentSps.id,
            nalPath,
            'PPS references an SPS outside this access unit',
            nal.offset,
          );
          parsedPps = parsedPpsValue;
          break;
        }
      case AVC_NAL_TYPE_IDR:
      case AVC_NAL_TYPE_NON_IDR:
        reachedVcl = true;
        vcl.add(nal);
        break;
      default:
        avcInvalid(nalPath, 'unreachable NAL type', nal.offset);
    }
  }
  requireAvc(
    vcl.isNotEmpty,
    path,
    'access unit contains no primary coded picture',
  );

  final idr = vcl[0].type == AVC_NAL_TYPE_IDR;
  requireAvc(
    vcl.every((nal) => (nal.type == AVC_NAL_TYPE_IDR) == idr),
    path,
    'an access unit mixes IDR and non-IDR slices',
  );
  requireAvc(
    accessUnit.key == idr,
    '$path.key',
    idr
        ? 'IDR access unit is missing its key assertion'
        : 'non-IDR access unit has a false key assertion',
  );
  requireAvc(
    frameIndex != 0 || idr,
    path,
    'frame zero of every unit must be an IDR picture',
  );
  requireAvc(
    (parsedSps == null) == (parsedPps == null),
    path,
    'SPS and PPS must be carried together',
  );
  requireAvc(
    !idr || (parsedSps != null && parsedPps != null),
    path,
    'every key/IDR access unit must carry SPS and PPS',
  );
  requireAvc(
    idr || (parsedSps == null && parsedPps == null),
    path,
    'parameter sets are permitted only in key/IDR access units',
  );

  AvcParameterSetState? parameterSets = activeParameterSets;
  if (parsedSps != null && parsedPps != null) {
    if (stableParameterSets != null) {
      _requireStableParameterSets(
        parsedSps,
        parsedPps,
        stableParameterSets,
        path,
      );
    }
    parameterSets = AvcParameterSetState(sps: parsedSps, pps: parsedPps);
  }
  requireAvc(
    parameterSets != null,
    path,
    'access unit has no usable SPS/PPS',
  );
  final resolvedParameterSets = parameterSets!;

  final macroblocksPerFrame = knownMacroblocksPerFrame ??
      validateAvcSpsAgainstProfile(
        resolvedParameterSets.sps,
        profile,
        '$path.sps',
        compatibilityPolicy,
      );
  final slices = <ParsedSliceHeader>[
    for (var index = 0; index < vcl.length; index += 1)
      parseSliceHeader(
        vcl[index],
        resolvedParameterSets.pps,
        resolvedParameterSets.sps,
        macroblocksPerFrame,
        '$path.slices[$index]',
      ),
  ];
  final primary = slices[0];
  requireAvc(
    primary.firstMacroblock == 0,
    '$path.slices[0]',
    'the first slice must begin at macroblock zero',
  );
  var previousFirstMacroblock = -1;
  for (var index = 0; index < slices.length; index += 1) {
    final slice = slices[index];
    requireAvc(
      samePrimaryPicture(primary, slice),
      '$path.slices[$index]',
      'access unit contains more than one primary coded picture',
    );
    requireAvc(
      slice.firstMacroblock > previousFirstMacroblock,
      '$path.slices[$index]',
      'slice macroblock starts must be strictly increasing',
    );
    previousFirstMacroblock = slice.firstMacroblock;
  }
  if (audPrimaryPicType != null) {
    requireAvc(
      audPrimaryPicType == 1 || primary.sliceType == 'I',
      '$path.nals[0]',
      'AUD primary_pic_type does not permit the coded P picture',
    );
  }

  final summary = AvcAccessUnitSummary(
    frameIndex: frameIndex,
    key: accessUnit.key,
    idr: idr,
    sliceType: primary.sliceType,
    sliceCount: slices.length,
    nalUnitTypes: nalTypes,
  );
  _validateCanonicalAvcSubset(
    frameIndex,
    summary,
    resolvedParameterSets,
    audPrimaryPicType,
    path,
  );
  _validatePictureSequence(
    primary,
    resolvedParameterSets.sps,
    orderState,
    path,
  );
  return AvcAccessUnitStateResult(
    summary: summary,
    parameterSets: resolvedParameterSets,
  );
}

void _validateCanonicalAvcSubset(
  int frameIndex,
  AvcAccessUnitSummary summary,
  AvcParameterSetState parameterSets,
  int? audPrimaryPicType,
  String path,
) {
  final first = frameIndex == 0;
  final expectedNalTypes = first ? const [9, 7, 8, 5] : const [9, 1];
  requireAvc(
    summary.nalUnitTypes.length == expectedNalTypes.length &&
        _listEquals(summary.nalUnitTypes, expectedNalTypes),
    path,
    first
        ? 'frame zero must contain exactly AUD/SPS/PPS/IDR'
        : 'later frames must contain exactly AUD/non-IDR',
  );
  requireAvc(
    summary.sliceCount == 1,
    path,
    'the production AVC profile requires exactly one slice per access unit',
  );
  requireAvc(
    first
        ? summary.idr && summary.sliceType == 'I' && summary.key
        : !summary.idr && summary.sliceType == 'P' && !summary.key,
    path,
    'unit pictures must be one frame-zero IDR I followed only by non-IDR P',
  );
  requireAvc(
    audPrimaryPicType == (first ? 0 : 1),
    '$path.nals[0]',
    first
        ? 'frame-zero AUD must announce an I picture'
        : 'later AUD must announce a P picture',
  );
  final sps = parameterSets.sps;
  requireAvc(
    sps.squareSampleAspect,
    '$path.sps',
    'the production AVC profile requires square sample aspect',
  );
  requireAvc(
    sps.timing.fixedFrameRate,
    '$path.sps',
    'the production AVC profile requires fixed_frame_rate_flag',
  );
  requireAvc(
    !sps.hrdPresent,
    '$path.sps',
    'the production AVC profile forbids HRD syntax',
  );
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

int _parseAud(AnnexBNalUnit nal, String path) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final primaryPicType = reader.readBits(3, 'primary_pic_type');
  requireAvc(
    primaryPicType == 0 || primaryPicType == 1,
    path,
    'AUD announces B, SP, or SI picture types',
    nal.offset + 1,
  );
  reader.readTrailingBits();
  return primaryPicType;
}

void _requireStableParameterSets(
  ParsedSps sps,
  ParsedPps pps,
  AvcParameterSetState stable,
  String path,
) {
  requireAvc(
    sps.payloadSignature == stable.sps.payloadSignature,
    '$path.sps',
    'SPS bytes changed within the rendition',
  );
  requireAvc(
    pps.payloadSignature == stable.pps.payloadSignature,
    '$path.pps',
    'PPS bytes changed within the rendition',
  );
}

int validateAvcSpsAgainstProfile(
  ParsedSps sps,
  AvcConstrainedBaselineProfile profile,
  String path, [
  AvcCompatibilityPolicy compatibilityPolicy = 'strict',
]) {
  if (compatibilityPolicy == 'strict') {
    requireAvc(
      sps.constraintSet2,
      path,
      'final ${avcCodecForLevel(sps.levelIdc)} output must assert constraint_set2_flag',
    );
  }
  requireAvc(
    sps.codedWidth == profile.codedWidth &&
        sps.codedHeight == profile.codedHeight,
    path,
    'SPS coded dimensions ${sps.codedWidth}x${sps.codedHeight} do not match the rendition',
  );
  final expectedCrop = profile.expectedDecodedStorageRect ??
      Rect(0, 0, profile.codedWidth, profile.codedHeight);
  requireAvc(
    sps.crop.left == expectedCrop.x &&
        sps.crop.top == expectedCrop.y &&
        sps.crop.right ==
            profile.codedWidth - expectedCrop.x - expectedCrop.width &&
        sps.crop.bottom ==
            profile.codedHeight - expectedCrop.y - expectedCrop.height &&
        sps.crop.visibleWidth == expectedCrop.width &&
        sps.crop.visibleHeight == expectedCrop.height,
    path,
    'SPS crop does not match the expected decoded storage rectangle',
  );
  final macroblocksPerFrame =
      (sps.codedWidth ~/ 16) * (sps.codedHeight ~/ 16);
  final level = avcLevelLimits(sps.levelIdc);
  final widthInMacroblocks = sps.codedWidth ~/ 16;
  final heightInMacroblocks = sps.codedHeight ~/ 16;
  requireAvc(
    widthInMacroblocks <= level.maximumMacroblockDimension &&
        heightInMacroblocks <= level.maximumMacroblockDimension,
    path,
    'SPS width or height exceeds its declared AVC level dimension limit',
  );
  requireAvc(
    macroblocksPerFrame <= level.maximumMacroblocksPerFrame,
    path,
    'SPS exceeds its declared AVC level macroblocks-per-frame limit',
  );
  requireAvc(
    BigInt.from(macroblocksPerFrame) *
            BigInt.from(profile.frameRate.numerator) <=
        BigInt.from(level.maximumMacroblocksPerSecond) *
            BigInt.from(profile.frameRate.denominator),
    path,
    'rendition exceeds its declared AVC level macroblocks-per-second limit',
  );
  requireAvc(
    profile.peakBitrate <= level.maximumBitrate,
    path,
    'rendition peak bitrate exceeds its declared AVC level',
  );
  final maximumCpbBits = _maximumCpbBitsByLevel[level.levelIdc] ?? 0;
  requireAvc(
    profile.cpbBufferBits <= maximumCpbBits,
    path,
    'rendition CPB exceeds its declared AVC level',
  );
  requireAvc(
    BigInt.from(sps.timing.timeScale) *
            BigInt.from(profile.frameRate.denominator) ==
        BigInt.from(2) *
            BigInt.from(sps.timing.numUnitsInTick) *
            BigInt.from(profile.frameRate.numerator),
    path,
    'SPS VUI timing does not match the rendition frame rate',
  );
  requireAvc(
    sps.timing.fixedFrameRate,
    path,
    'fixed_frame_rate_flag must be one',
  );
  final maximumDpbFramesFromLevel =
      level.maximumDpbMacroblocks ~/ macroblocksPerFrame;
  final maximumDpbFrames =
      16 < maximumDpbFramesFromLevel ? 16 : maximumDpbFramesFromLevel;
  requireAvc(
    sps.maxDecFrameBuffering <= maximumDpbFrames,
    path,
    'SPS max_dec_frame_buffering exceeds its declared AVC level',
  );
  final hrdMaximumBitrate = sps.hrdMaximumBitrate;
  if (hrdMaximumBitrate != null) {
    requireAvc(
      hrdMaximumBitrate <= profile.peakBitrate,
      path,
      'SPS HRD bitrate exceeds the declared peak bitrate',
    );
  }
  final hrdMaximumCpbBits = sps.hrdMaximumCpbBits;
  if (hrdMaximumCpbBits != null) {
    requireAvc(
      hrdMaximumCpbBits <= profile.cpbBufferBits,
      path,
      'SPS HRD CPB exceeds the configured VBV buffer',
    );
  }
  requireAvc(
    !sps.color.fullRange &&
        sps.color.colourPrimaries == 1 &&
        sps.color.transferCharacteristics == 1 &&
        sps.color.matrixCoefficients == 1,
    path,
    'the production AVC profile requires BT.709 limited-range colour signalling',
  );
  return macroblocksPerFrame;
}

void _validatePictureSequence(
  ParsedSliceHeader picture,
  ParsedSps sps,
  AvcPictureOrderState state,
  String path,
) {
  final maximumFrameNum = 1 << sps.frameNumBits;
  if (picture.idr) {
    requireAvc(picture.frameNum == 0, path, 'IDR frame_num must be zero');
    state.previousFrameNum = 0;
    state.frameNumOffset = 0;
    state.previousPoc = -1;
    state.previousPocMsb = 0;
    state.previousPocLsb = 0;
  } else {
    final expectedFrameNum = (state.previousFrameNum + 1) % maximumFrameNum;
    requireAvc(
      picture.frameNum == expectedFrameNum,
      path,
      'reference frame_num is not consecutive',
    );
    if (picture.frameNum < state.previousFrameNum) {
      state.frameNumOffset += maximumFrameNum;
    }
  }

  final poc = _calculatePictureOrderCount(picture, sps, state);
  requireAvc(
    picture.idr ? poc == 0 : poc > state.previousPoc,
    path,
    'picture order count is reordered or non-increasing',
  );
  state.previousPoc = poc;
  state.previousFrameNum = picture.frameNum;
}

int _calculatePictureOrderCount(
  ParsedSliceHeader picture,
  ParsedSps sps,
  AvcPictureOrderState state,
) {
  final syntax = sps.picOrderCount;
  if (syntax is PicOrderCountType2) {
    return picture.idr ? 0 : 2 * (state.frameNumOffset + picture.frameNum);
  }
  if (syntax is PicOrderCountType1) {
    if (picture.idr) {
      return picture.deltaPicOrderCnt0;
    }
    final absoluteFrameNum = state.frameNumOffset + picture.frameNum;
    final cycleLength = syntax.offsetForRefFrame.length;
    var expected = 0;
    if (absoluteFrameNum > 0 && cycleLength > 0) {
      final expectedDelta = syntax.offsetForRefFrame
          .fold<int>(0, (total, offset) => total + offset);
      final cycleCount = (absoluteFrameNum - 1) ~/ cycleLength;
      final frameInCycle = (absoluteFrameNum - 1) % cycleLength;
      expected = cycleCount * expectedDelta;
      for (var index = 0; index <= frameInCycle; index += 1) {
        expected += syntax.offsetForRefFrame[index];
      }
    }
    final top = expected + picture.deltaPicOrderCnt0;
    final bottom =
        top + syntax.offsetForTopToBottomField + picture.deltaPicOrderCnt1;
    return top < bottom ? top : bottom;
  }

  syntax as PicOrderCountType0;
  final lsb = picture.picOrderCntLsb;
  if (lsb == null) {
    avcInvalid('slice', 'pic_order_cnt_lsb is missing');
  }
  final maximumLsb = 1 << syntax.lsbBits;
  var msb = 0;
  if (!picture.idr) {
    if (lsb < state.previousPocLsb &&
        state.previousPocLsb - lsb >= maximumLsb / 2) {
      msb = state.previousPocMsb + maximumLsb;
    } else if (lsb > state.previousPocLsb &&
        lsb - state.previousPocLsb > maximumLsb / 2) {
      msb = state.previousPocMsb - maximumLsb;
    } else {
      msb = state.previousPocMsb;
    }
  }
  final top = msb + lsb;
  final bottom = top + picture.deltaPicOrderCntBottom;
  state.previousPocMsb = msb;
  state.previousPocLsb = lsb;
  return top < bottom ? top : bottom;
}

AvcParameterSetSummary createAvcParameterSetSummary(ParsedSps sps) {
  return AvcParameterSetSummary(
    constraintSet2: sps.constraintSet2,
    levelIdc: sps.levelIdc,
    codedWidth: sps.codedWidth,
    codedHeight: sps.codedHeight,
    crop: sps.crop,
    maxDecFrameBuffering: sps.maxDecFrameBuffering,
    hrdPresent: sps.hrdPresent,
    fixedFrameRate: sps.timing.fixedFrameRate,
    squareSampleAspect: sps.squareSampleAspect,
    color: sps.color,
  );
}

AvcPictureOrderState createAvcPictureOrderState() => AvcPictureOrderState();

AvcPictureOrderState cloneAvcPictureOrderState(AvcPictureOrderState state) =>
    AvcPictureOrderState(
      previousFrameNum: state.previousFrameNum,
      frameNumOffset: state.frameNumOffset,
      previousPoc: state.previousPoc,
      previousPocMsb: state.previousPocMsb,
      previousPocLsb: state.previousPocLsb,
    );
