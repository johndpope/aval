/// Inspects every access unit in an independently decodable H264 rendition.
///
/// This is intentionally a syntax/dependency verifier, not a decoder. It
/// accepts only the production High-profile subset and returns a deeply
/// immutable scalar summary; no caller-owned byte views escape.
///
/// Dart port of `packages/format/src/h264/inspector.ts`.
library;

import 'dart:math' as math;

import '../checked_integer.dart' show maxSafeInteger;
import '../constants.dart' show formatDefaultBudgets, identifierPattern;
import '../errors.dart';
import '../model.dart' show Rect;
import 'annex_b.dart';
import 'bit_reader.dart';
import 'codec.dart' show h264CodecForLevel, h264LevelLimits;
import 'failure.dart';
import 'parameter_sets.dart';
import 'slice_header.dart';
import 'types.dart';

class H264ParameterSetState {
  const H264ParameterSetState({required this.sps, required this.pps});

  final ParsedSps sps;
  final ParsedPps pps;
}

/// Mutable picture-order tracking state threaded through one unit's frames.
class H264PictureOrderState {
  H264PictureOrderState({
    this.previousReferenceFrameNum = 0,
    this.previousReferenceFrameNumOffset = 0,
    this.previousPocMsb = 0,
    this.previousPocLsb = 0,
  });

  int previousReferenceFrameNum;
  int previousReferenceFrameNumOffset;
  int previousPocMsb;
  int previousPocLsb;
}

/// Internal per-picture draft before presentation order is derived. Mirrors
/// TS `H264AccessUnitDraft`.
class _H264AccessUnitDraft {
  const _H264AccessUnitDraft({
    required this.decodeIndex,
    required this.pictureOrderCount,
    required this.key,
    required this.idr,
    required this.sliceType,
    required this.sliceCount,
    required this.nalUnitTypes,
  });

  final int decodeIndex;
  final int pictureOrderCount;
  final bool key;
  final bool idr;
  final H264SliceType sliceType;
  final int sliceCount;
  final List<int> nalUnitTypes;
}

class _H264AccessUnitStateResult {
  const _H264AccessUnitStateResult({
    required this.summary,
    required this.parameterSets,
  });

  final _H264AccessUnitDraft summary;
  final H264ParameterSetState parameterSets;
}

/// Inspects every access unit in an independently decodable rendition.
H264RenditionInspection inspectH264AnnexBRendition(
  H264RenditionInspectionInput input,
) =>
    _inspectRendition(input);

H264RenditionInspection _inspectRendition(
  H264RenditionInspectionInput input,
) {
  try {
    final profile = cloneH264Profile(input.profile);
    requireH264(input.units.isNotEmpty, 'units', 'at least one unit is required');
    requireH264(
      input.units.length <= formatDefaultBudgets.maxUnits,
      'units',
      'unit count exceeds the format budget',
    );

    final seenUnitIds = <String>{};
    H264ParameterSetState? stableParameterSets;
    int? macroblocksPerFrame;
    var totalFrames = 0;
    final units = <H264UnitInspection>[];

    for (var unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
      final unit = input.units[unitIndex];
      final unitPath = 'units[$unitIndex]';
      requireH264(
        identifierPattern.hasMatch(unit.id),
        '$unitPath.id',
        'unit id is invalid',
      );
      requireH264(
        !seenUnitIds.contains(unit.id),
        '$unitPath.id',
        'unit id is duplicated',
      );
      seenUnitIds.add(unit.id);
      requireH264(
        unit.accessUnits.isNotEmpty,
        '$unitPath.accessUnits',
        'unit must contain at least one access unit',
      );
      totalFrames += unit.accessUnits.length;
      requireH264(
        totalFrames <= formatDefaultBudgets.maxTotalUnitFrames,
        '$unitPath.accessUnits',
        'total frame count exceeds the format budget',
      );

      final orderState = _createH264PictureOrderState();
      final drafts = <_H264AccessUnitDraft>[];
      final decodedPictureOrderCounts = <int>{};
      var activeParameterSets = stableParameterSets;

      for (
        var decodeIndex = 0;
        decodeIndex < unit.accessUnits.length;
        decodeIndex += 1
      ) {
        final accessUnit = unit.accessUnits[decodeIndex];
        final accessUnitPath = '$unitPath.accessUnits[$decodeIndex]';
        validateH264AccessUnitInput(accessUnit, accessUnitPath);
        final result = _inspectH264AccessUnitStatefully(
          accessUnit,
          decodeIndex,
          accessUnitPath,
          activeParameterSets,
          stableParameterSets,
          profile,
          orderState,
          macroblocksPerFrame,
        );
        activeParameterSets = result.parameterSets;
        if (stableParameterSets == null) {
          stableParameterSets = result.parameterSets;
          macroblocksPerFrame = validateH264SpsAgainstProfile(
            stableParameterSets.sps,
            profile,
            '$accessUnitPath.sps',
          );
        }
        requireH264(
          !decodedPictureOrderCounts.contains(result.summary.pictureOrderCount),
          accessUnitPath,
          'unit contains duplicate picture-order counts',
        );
        decodedPictureOrderCounts.add(result.summary.pictureOrderCount);
        drafts.add(result.summary);
      }

      final parameterSets = activeParameterSets;
      if (parameterSets == null) {
        h264Invalid(unitPath, 'unit has no parameter sets');
      }
      final decodeToPresentation = _deriveH264PresentationOrder(
        drafts,
        parameterSets.sps.maxNumReorderFrames,
        '$unitPath.accessUnits',
      );
      final accessUnits = <H264AccessUnitSummary>[
        for (final draft in drafts)
          H264AccessUnitSummary(
            decodeIndex: draft.decodeIndex,
            presentationIndex: decodeToPresentation[draft.decodeIndex],
            pictureOrderCount: draft.pictureOrderCount,
            key: draft.key,
            idr: draft.idr,
            sliceType: draft.sliceType,
            sliceCount: draft.sliceCount,
            nalUnitTypes: draft.nalUnitTypes,
          ),
      ];
      units.add(
        H264UnitInspection(
          id: unit.id,
          accessUnits: List.unmodifiable(accessUnits),
          decodeToPresentation: decodeToPresentation,
        ),
      );
    }

    if (stableParameterSets == null || macroblocksPerFrame == null) {
      h264Invalid('units', 'no H264 parameter sets were found');
    }
    final parameterSet = createH264ParameterSetSummary(stableParameterSets.sps);
    return H264RenditionInspection(
      parameterSet: parameterSet,
      macroblocksPerFrame: macroblocksPerFrame,
      units: List.unmodifiable(units),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.profileInvalid, 'H264 inspection failed');
  }
}

H264Profile cloneH264Profile(H264Profile profile) {
  _positiveInteger(profile.codedWidth, 'profile.codedWidth');
  _positiveInteger(profile.codedHeight, 'profile.codedHeight');
  final expectedVisibleRect = _cloneExpectedVisibleRect(
    profile.expectedVisibleRect,
    profile.codedWidth,
    profile.codedHeight,
  );
  _positiveInteger(profile.frameRate.numerator, 'profile.frameRate.numerator');
  _positiveInteger(
    profile.frameRate.denominator,
    'profile.frameRate.denominator',
  );
  requireH264(
    profile.requireBt709LimitedRange == true,
    'profile.requireBt709LimitedRange',
    'the production H264 profile requires BT.709 limited range',
  );
  return H264Profile(
    codedWidth: profile.codedWidth,
    codedHeight: profile.codedHeight,
    expectedVisibleRect: expectedVisibleRect,
    frameRate: H264FrameRate(
      numerator: profile.frameRate.numerator,
      denominator: profile.frameRate.denominator,
    ),
  );
}

Rect _cloneExpectedVisibleRect(Rect? value, int codedWidth, int codedHeight) {
  if (value == null) {
    return Rect(0, 0, codedWidth, codedHeight);
  }
  requireH264(
    value.x == 0 && value.y == 0,
    'profile.expectedVisibleRect',
    'expected visible rectangle must begin at the coded origin',
  );
  _positiveIntegerMax(value.width, 'profile.expectedVisibleRect[2]', codedWidth);
  _positiveIntegerMax(
    value.height,
    'profile.expectedVisibleRect[3]',
    codedHeight,
  );
  requireH264(
    value.width % 2 == 0 && value.height % 2 == 0,
    'profile.expectedVisibleRect',
    'expected visible dimensions must be even for yuv420p',
  );
  requireH264(
    (codedWidth - value.width) % 2 == 0 &&
        (codedHeight - value.height) % 2 == 0,
    'profile.expectedVisibleRect',
    'expected visible crop must use 4:2:0 crop units',
  );
  return Rect(0, 0, value.width, value.height);
}

void _positiveInteger(int value, String path) {
  requireH264(
    value > 0 && value <= maxSafeInteger,
    path,
    'must be a positive safe integer',
  );
}

void _positiveIntegerMax(int value, String path, int maximum) {
  requireH264(
    value > 0 && value <= maximum,
    path,
    'must be a positive safe integer no greater than $maximum',
  );
}

void validateH264AccessUnitInput(H264AccessUnitInput accessUnit, String path) {
  requireH264(
    accessUnit.bytes.length <= formatDefaultBudgets.maxChunkBytes,
    '$path.bytes',
    'access unit exceeds the sample budget',
  );
}

_H264AccessUnitStateResult _inspectH264AccessUnitStatefully(
  H264AccessUnitInput accessUnit,
  int decodeIndex,
  String path,
  H264ParameterSetState? activeParameterSets,
  H264ParameterSetState? stableParameterSets,
  H264Profile profile,
  H264PictureOrderState orderState,
  int? knownMacroblocksPerFrame,
) {
  final nals = splitAnnexBAccessUnit(accessUnit.bytes, '$path.bytes');
  requireH264(
    nals.every((nal) => nal.prefixLength == 4),
    '$path.bytes',
    'stored H264 access units must use canonical four-byte start codes',
  );
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
      case H264_NAL_TYPE_AUD:
        requireH264(
          index == 0 && audPrimaryPicType == null,
          nalPath,
          'AUD must appear once, before every other NAL',
          nal.offset,
        );
        audPrimaryPicType = _parseAud(nal, nalPath);
        break;
      case H264_NAL_TYPE_SPS:
        requireH264(
          !reachedVcl && parsedSps == null && parsedPps == null,
          nalPath,
          'SPS must appear once before PPS and VCL',
          nal.offset,
        );
        parsedSps = parseSps(nal, nalPath);
        break;
      case H264_NAL_TYPE_PPS:
        requireH264(
          !reachedVcl && parsedPps == null && parsedSps != null,
          nalPath,
          'PPS must appear once after SPS and before VCL',
          nal.offset,
        );
        final currentSps = parsedSps!;
        final parsedPpsValue = parsePps(nal, nalPath);
        requireH264(
          parsedPpsValue.spsId == currentSps.id,
          nalPath,
          'PPS references an SPS outside this access unit',
          nal.offset,
        );
        parsedPps = parsedPpsValue;
        break;
      case H264_NAL_TYPE_IDR:
      case H264_NAL_TYPE_NON_IDR:
        reachedVcl = true;
        vcl.add(nal);
        break;
      default:
        h264Invalid(nalPath, 'unreachable NAL type', nal.offset);
    }
  }
  requireH264(
    vcl.isNotEmpty,
    path,
    'access unit contains no primary coded picture',
  );

  final idr = vcl[0].type == H264_NAL_TYPE_IDR;
  requireH264(
    vcl.every((nal) => (nal.type == H264_NAL_TYPE_IDR) == idr),
    path,
    'an access unit mixes IDR and non-IDR slices',
  );
  requireH264(
    accessUnit.key == idr,
    '$path.key',
    idr
        ? 'IDR access unit is missing its key assertion'
        : 'non-IDR access unit has a false key assertion',
  );
  requireH264(
    decodeIndex != 0 || idr,
    path,
    'frame zero of every unit must be an IDR picture',
  );
  requireH264(
    (parsedSps == null) == (parsedPps == null),
    path,
    'SPS and PPS must be carried together',
  );
  requireH264(
    !idr || (parsedSps != null && parsedPps != null),
    path,
    'every key/IDR access unit must carry SPS and PPS',
  );
  requireH264(
    idr || (parsedSps == null && parsedPps == null),
    path,
    'parameter sets are permitted only in key/IDR access units',
  );

  H264ParameterSetState? parameterSets = activeParameterSets;
  if (parsedSps != null && parsedPps != null) {
    if (stableParameterSets != null) {
      _requireStableParameterSets(
        parsedSps,
        parsedPps,
        stableParameterSets,
        path,
      );
    }
    parameterSets = H264ParameterSetState(sps: parsedSps, pps: parsedPps);
  }
  if (parameterSets == null) {
    h264Invalid(path, 'access unit has no usable SPS/PPS');
  }

  final macroblocksPerFrame = knownMacroblocksPerFrame ??
      validateH264SpsAgainstProfile(
        parameterSets.sps,
        profile,
        '$path.sps',
      );
  final slices = <ParsedSliceHeader>[
    for (var index = 0; index < vcl.length; index += 1)
      parseSliceHeader(
        vcl[index],
        parameterSets.pps,
        parameterSets.sps,
        macroblocksPerFrame,
        '$path.slices[$index]',
      ),
  ];
  final primary = slices[0];
  requireH264(
    primary.firstMacroblock == 0,
    '$path.slices[0]',
    'the first slice must begin at macroblock zero',
  );
  var previousFirstMacroblock = -1;
  for (var index = 0; index < slices.length; index += 1) {
    final slice = slices[index];
    requireH264(
      samePrimaryPicture(primary, slice),
      '$path.slices[$index]',
      'access unit contains more than one primary coded picture',
    );
    requireH264(
      slice.firstMacroblock > previousFirstMacroblock,
      '$path.slices[$index]',
      'slice macroblock starts must be strictly increasing',
    );
    previousFirstMacroblock = slice.firstMacroblock;
  }
  final pictureOrderCount = _validatePictureSequence(
    primary,
    parameterSets.sps,
    orderState,
    path,
  );

  final summary = _H264AccessUnitDraft(
    decodeIndex: decodeIndex,
    pictureOrderCount: pictureOrderCount,
    key: accessUnit.key,
    idr: idr,
    sliceType: primary.sliceType,
    sliceCount: slices.length,
    nalUnitTypes: nalTypes,
  );
  _validateCanonicalH264Subset(
    decodeIndex,
    summary,
    parameterSets,
    audPrimaryPicType,
    path,
  );
  return _H264AccessUnitStateResult(
    summary: summary,
    parameterSets: parameterSets,
  );
}

void _validateCanonicalH264Subset(
  int decodeIndex,
  _H264AccessUnitDraft summary,
  H264ParameterSetState parameterSets,
  int? audPrimaryPicType,
  String path,
) {
  final first = decodeIndex == 0;
  final expectedNalTypes = first ? const [9, 7, 8, 5] : const [9, 1];
  requireH264(
    summary.nalUnitTypes.length == expectedNalTypes.length &&
        _listEquals(summary.nalUnitTypes, expectedNalTypes),
    path,
    first
        ? 'frame zero must contain exactly AUD/SPS/PPS/IDR'
        : 'later frames must contain exactly AUD/non-IDR',
  );
  requireH264(
    summary.sliceCount == 1,
    path,
    'the production H264 profile requires exactly one slice per access unit',
  );
  requireH264(
    first
        ? summary.idr && summary.sliceType == 'I' && summary.key
        : !summary.idr &&
            (summary.sliceType == 'P' || summary.sliceType == 'B') &&
            !summary.key,
    path,
    'unit pictures must be one decode-zero IDR I followed by non-IDR P/B pictures',
  );
  final expectedAudPrimaryPicType = summary.sliceType == 'I'
      ? 0
      : summary.sliceType == 'P'
          ? 1
          : 2;
  requireH264(
    audPrimaryPicType == expectedAudPrimaryPicType,
    '$path.nals[0]',
    'AUD primary_pic_type does not match the coded picture',
  );
  final sps = parameterSets.sps;
  requireH264(
    sps.squareSampleAspect,
    '$path.sps',
    'the production H264 profile requires square sample aspect',
  );
  requireH264(
    sps.timing.fixedFrameRate,
    '$path.sps',
    'the production H264 profile requires fixed_frame_rate_flag',
  );
  requireH264(
    !sps.hrdPresent,
    '$path.sps',
    'the production H264 profile forbids HRD syntax',
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
  requireH264(
    primaryPicType == 0 || primaryPicType == 1 || primaryPicType == 2,
    path,
    'AUD announces SP or SI picture types',
    nal.offset + 1,
  );
  reader.readTrailingBits();
  return primaryPicType;
}

void _requireStableParameterSets(
  ParsedSps sps,
  ParsedPps pps,
  H264ParameterSetState stable,
  String path,
) {
  requireH264(
    sps.payloadSignature == stable.sps.payloadSignature,
    '$path.sps',
    'SPS bytes changed within the rendition',
  );
  requireH264(
    pps.payloadSignature == stable.pps.payloadSignature,
    '$path.pps',
    'PPS bytes changed within the rendition',
  );
}

int validateH264SpsAgainstProfile(
  ParsedSps sps,
  H264Profile profile,
  String path,
) {
  requireH264(
    sps.codedWidth == profile.codedWidth &&
        sps.codedHeight == profile.codedHeight,
    path,
    'SPS coded dimensions ${sps.codedWidth}x${sps.codedHeight} do not match the rendition',
  );
  final expectedCrop = profile.expectedVisibleRect ??
      Rect(0, 0, profile.codedWidth, profile.codedHeight);
  requireH264(
    sps.crop.left == expectedCrop.x &&
        sps.crop.top == expectedCrop.y &&
        sps.crop.right ==
            profile.codedWidth - expectedCrop.x - expectedCrop.width &&
        sps.crop.bottom ==
            profile.codedHeight - expectedCrop.y - expectedCrop.height &&
        sps.crop.visibleWidth == expectedCrop.width &&
        sps.crop.visibleHeight == expectedCrop.height,
    path,
    'SPS crop does not match the expected visible rectangle',
  );
  final macroblocksPerFrame = (sps.codedWidth ~/ 16) * (sps.codedHeight ~/ 16);
  final level = h264LevelLimits(sps.levelIdc);
  final widthInMacroblocks = sps.codedWidth ~/ 16;
  final heightInMacroblocks = sps.codedHeight ~/ 16;
  requireH264(
    widthInMacroblocks <= level.maximumMacroblockDimension &&
        heightInMacroblocks <= level.maximumMacroblockDimension,
    path,
    'SPS width or height exceeds its declared H264 level dimension limit',
  );
  requireH264(
    macroblocksPerFrame <= level.maximumMacroblocksPerFrame,
    path,
    'SPS exceeds its declared H264 level macroblocks-per-frame limit',
  );
  requireH264(
    BigInt.from(macroblocksPerFrame) *
            BigInt.from(profile.frameRate.numerator) <=
        BigInt.from(level.maximumMacroblocksPerSecond) *
            BigInt.from(profile.frameRate.denominator),
    path,
    'rendition exceeds its declared H264 level macroblocks-per-second limit',
  );
  requireH264(
    BigInt.from(sps.timing.timeScale) *
            BigInt.from(profile.frameRate.denominator) ==
        BigInt.from(2) *
            BigInt.from(sps.timing.numUnitsInTick) *
            BigInt.from(profile.frameRate.numerator),
    path,
    'SPS VUI timing does not match the rendition frame rate',
  );
  requireH264(
    sps.timing.fixedFrameRate,
    path,
    'fixed_frame_rate_flag must be one',
  );
  final maximumDpbFramesFromLevel =
      level.maximumDpbMacroblocks ~/ macroblocksPerFrame;
  final maximumDpbFrames =
      16 < maximumDpbFramesFromLevel ? 16 : maximumDpbFramesFromLevel;
  requireH264(
    sps.maxDecFrameBuffering <= maximumDpbFrames,
    path,
    'SPS max_dec_frame_buffering exceeds its declared H264 level',
  );
  requireH264(
    !sps.color.fullRange &&
        sps.color.colourPrimaries == 1 &&
        sps.color.transferCharacteristics == 1 &&
        sps.color.matrixCoefficients == 1,
    path,
    'the production H264 profile requires BT.709 limited-range colour signalling',
  );
  return macroblocksPerFrame;
}

int _validatePictureSequence(
  ParsedSliceHeader picture,
  ParsedSps sps,
  H264PictureOrderState state,
  String path,
) {
  final maximumFrameNum = 1 << sps.frameNumBits;
  var frameNumOffset = 0;
  if (picture.idr) {
    requireH264(picture.frameNum == 0, path, 'IDR frame_num must be zero');
    state.previousReferenceFrameNum = 0;
    state.previousReferenceFrameNumOffset = 0;
    state.previousPocMsb = 0;
    state.previousPocLsb = 0;
  } else {
    final expectedFrameNum =
        (state.previousReferenceFrameNum + 1) % maximumFrameNum;
    requireH264(
      picture.frameNum == expectedFrameNum,
      path,
      'frame_num does not identify the next short-term picture',
    );
    frameNumOffset = state.previousReferenceFrameNumOffset +
        (picture.frameNum < state.previousReferenceFrameNum
            ? maximumFrameNum
            : 0);
  }

  final poc = _calculatePictureOrderCount(picture, sps, state, frameNumOffset);
  requireH264(
    (poc >= -maxSafeInteger && poc <= maxSafeInteger) &&
        (!picture.idr || poc == 0),
    path,
    'picture order count is invalid',
  );
  if (picture.referenceIdc != 0) {
    state.previousReferenceFrameNum = picture.frameNum;
    state.previousReferenceFrameNumOffset = frameNumOffset;
  }
  return poc;
}

int _calculatePictureOrderCount(
  ParsedSliceHeader picture,
  ParsedSps sps,
  H264PictureOrderState state,
  int frameNumOffset,
) {
  final syntax = sps.picOrderCount;
  if (syntax is PicOrderCountType2) {
    if (picture.idr) return 0;
    final absoluteFrameNum = frameNumOffset + picture.frameNum;
    return picture.referenceIdc == 0
        ? 2 * absoluteFrameNum - 1
        : 2 * absoluteFrameNum;
  }
  if (syntax is PicOrderCountType1) {
    if (picture.idr) {
      return picture.deltaPicOrderCnt0;
    }
    var absoluteFrameNum = frameNumOffset + picture.frameNum;
    if (picture.referenceIdc == 0 && absoluteFrameNum > 0) {
      absoluteFrameNum -= 1;
    }
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
    if (picture.referenceIdc == 0) {
      expected += syntax.offsetForNonRefPic;
    }
    final top = expected + picture.deltaPicOrderCnt0;
    final bottom =
        top + syntax.offsetForTopToBottomField + picture.deltaPicOrderCnt1;
    return top < bottom ? top : bottom;
  }

  syntax as PicOrderCountType0;
  final lsb = picture.picOrderCntLsb;
  if (lsb == null) {
    h264Invalid('slice', 'pic_order_cnt_lsb is missing');
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
  if (picture.referenceIdc != 0) {
    state.previousPocMsb = msb;
    state.previousPocLsb = lsb;
  }
  return top < bottom ? top : bottom;
}

List<int> _deriveH264PresentationOrder(
  List<_H264AccessUnitDraft> pictures,
  int maximumReorderFrames,
  String path,
) {
  requireH264(pictures.isNotEmpty, path, 'unit contains no decoded pictures');
  final sorted = [...pictures]
    ..sort((left, right) => left.pictureOrderCount - right.pictureOrderCount);
  requireH264(
    sorted[0].decodeIndex == 0 && sorted[0].pictureOrderCount == 0,
    path,
    'the unit IDR must be the first presentation picture',
  );
  final decodeToPresentation = List<int?>.filled(pictures.length, null);
  int? previousPictureOrderCount;
  for (
    var presentationIndex = 0;
    presentationIndex < sorted.length;
    presentationIndex += 1
  ) {
    final picture = sorted[presentationIndex];
    requireH264(
      previousPictureOrderCount == null ||
          picture.pictureOrderCount > previousPictureOrderCount,
      path,
      'unit picture-order counts must be unique',
    );
    requireH264(
      picture.decodeIndex >= 0 &&
          picture.decodeIndex < pictures.length &&
          decodeToPresentation[picture.decodeIndex] == null,
      path,
      'unit decode index is duplicated or out of range',
    );
    decodeToPresentation[picture.decodeIndex] = presentationIndex;
    previousPictureOrderCount = picture.pictureOrderCount;
  }
  var requiredReorderFrames = 0;
  for (
    var decodeIndex = 0;
    decodeIndex < decodeToPresentation.length;
    decodeIndex += 1
  ) {
    final presentationIndex = decodeToPresentation[decodeIndex];
    requireH264(presentationIndex != null, path, 'decode order has a gap');
    requiredReorderFrames = math.max(
      requiredReorderFrames,
      decodeIndex - presentationIndex!,
    );
  }
  requireH264(
    requiredReorderFrames <= maximumReorderFrames,
    path,
    'derived presentation reordering exceeds the SPS declaration',
  );
  return List<int>.unmodifiable([for (final value in decodeToPresentation) value!]);
}

H264ParameterSetSummary createH264ParameterSetSummary(ParsedSps sps) {
  return H264ParameterSetSummary(
    codec: h264CodecForLevel(sps.levelIdc),
    levelIdc: sps.levelIdc,
    codedWidth: sps.codedWidth,
    codedHeight: sps.codedHeight,
    crop: sps.crop,
    maxNumRefFrames: sps.maxNumRefFrames,
    maxNumReorderFrames: sps.maxNumReorderFrames,
    maxDecFrameBuffering: sps.maxDecFrameBuffering,
    hrdPresent: sps.hrdPresent,
    fixedFrameRate: sps.timing.fixedFrameRate,
    squareSampleAspect: sps.squareSampleAspect,
    color: sps.color,
  );
}

H264PictureOrderState _createH264PictureOrderState() =>
    H264PictureOrderState();
