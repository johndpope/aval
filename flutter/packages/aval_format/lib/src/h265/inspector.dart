/// Strict HEVC rendition inspector: proves each graph unit is independently
/// decodable and derives decode/presentation order.
///
/// Dart port of `packages/format/src/h265/inspector.ts`.
library;

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';
import 'annex_b.dart'
    show
        H265_MAX_ACCESS_UNIT_BYTES,
        H265_NAL_AUD,
        H265_NAL_PPS,
        H265_NAL_SPS,
        H265_NAL_VPS,
        H265AnnexBNalUnit,
        isH265RandomAccessNalType,
        isH265VclNalType,
        splitH265AnnexBAccessUnit;
import 'bit_reader.dart';
import 'codec.dart' show createH265VideoDecoderConfig, h265CodecString;
import 'failure.dart';
import 'parameter_sets.dart'
    show
        ParsedH265Pps,
        ParsedH265Sps,
        ParsedH265Vps,
        parseH265Pps,
        parseH265Sps,
        parseH265Vps,
        sameH265ProfileTierLevel;
import 'presentation_order.dart'
    show
        H265DecodedPictureOrder,
        createH265PictureOrderState,
        deriveH265PictureOrderCount,
        deriveH265PresentationOrder;
import 'slice_header.dart' show ParsedH265SliceHeader, parseH265SliceHeader;
import 'types.dart'
    show
        H265AccessUnitInput,
        H265AccessUnitSummary,
        H265MainProfile,
        H265ParameterSetSummary,
        H265RandomAccessKind,
        H265RenditionInspection,
        H265RenditionInspectionInput,
        H265UnitInspection;

final RegExp _identifierPattern = RegExp(r'^[a-z][a-z0-9._-]{0,63}$');
const int _maxUnits = 96;
const int _maxTotalAccessUnits = 1000000;

class _H265ParameterSetState {
  const _H265ParameterSetState({
    required this.vps,
    required this.sps,
    required this.pps,
  });

  final ParsedH265Vps vps;
  final ParsedH265Sps sps;
  final ParsedH265Pps pps;
}

class _DraftSummary {
  const _DraftSummary({
    required this.decodeIndex,
    required this.pictureOrderCount,
    required this.key,
    required this.randomAccess,
    required this.sliceType,
    required this.temporalId,
    required this.referencedPictureOrderCounts,
    required this.nalUnitTypes,
  });

  final int decodeIndex;
  final int pictureOrderCount;
  final bool key;
  final H265RandomAccessKind? randomAccess;
  final String sliceType;
  final int temporalId;
  final List<int> referencedPictureOrderCounts;
  final List<int> nalUnitTypes;
}

class _InspectedAccessUnit {
  const _InspectedAccessUnit({
    required this.parameterSets,
    required this.vcl,
    required this.slice,
  });

  final _H265ParameterSetState parameterSets;
  final H265AnnexBNalUnit vcl;
  final ParsedH265SliceHeader slice;
}

/// Inspects canonical HEVC access units and proves each graph unit is closed.
///
/// Port of `inspectH265AnnexBRendition` (`src/h265/inspector.ts:63`).
H265RenditionInspection inspectH265AnnexBRendition(
  H265RenditionInspectionInput input,
) {
  try {
    final profile = _cloneH265Profile(input.profile);
    requireH265(
      input.units.isNotEmpty,
      'units',
      'at least one unit is required',
    );
    requireH265(
      input.units.length <= _maxUnits,
      'units',
      'unit count exceeds the HEVC inspection budget',
    );
    final ids = <String>{};
    _H265ParameterSetState? stableParameterSets;
    var totalAccessUnits = 0;
    final units = <H265UnitInspection>[];

    for (var unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
      final unit = input.units[unitIndex];
      final unitPath = 'units[$unitIndex]';
      requireH265(
        _identifierPattern.hasMatch(unit.id),
        '$unitPath.id',
        'unit id is invalid',
      );
      requireH265(
        !ids.contains(unit.id),
        '$unitPath.id',
        'unit id is duplicated',
      );
      ids.add(unit.id);
      requireH265(
        unit.accessUnits.isNotEmpty,
        '$unitPath.accessUnits',
        'unit must contain at least one access unit',
      );
      totalAccessUnits += unit.accessUnits.length;
      requireH265(
        totalAccessUnits <= maxSafeInteger &&
            totalAccessUnits <= _maxTotalAccessUnits,
        '$unitPath.accessUnits',
        'total access-unit count exceeds the HEVC inspection budget',
      );

      final orderState = createH265PictureOrderState();
      final decodedPocs = <int>{};
      final drafts = <_DraftSummary>[];
      _H265ParameterSetState? activeParameterSets;
      for (var decodeIndex = 0;
          decodeIndex < unit.accessUnits.length;
          decodeIndex += 1) {
        final accessUnit = unit.accessUnits[decodeIndex];
        final path = '$unitPath.accessUnits[$decodeIndex]';
        _validateAccessUnitInput(accessUnit, path);
        final nals = splitH265AnnexBAccessUnit(accessUnit.bytes, '$path.bytes');
        requireH265(
          nals.every((nal) => nal.prefixLength == 4),
          '$path.bytes',
          'stored HEVC access units must use canonical four-byte start codes',
        );
        final inspected = _inspectAccessUnitStructure(
          nals,
          accessUnit,
          decodeIndex,
          path,
          activeParameterSets,
          stableParameterSets,
        );
        activeParameterSets = inspected.parameterSets;
        if (stableParameterSets == null) {
          stableParameterSets = inspected.parameterSets;
          _validateParameterSetsAgainstProfile(
            stableParameterSets,
            profile,
            path,
          );
        }
        final sps = inspected.parameterSets.sps;
        final pictureOrderCount = deriveH265PictureOrderCount(
          inspected.vcl.type,
          inspected.vcl.temporalId,
          inspected.slice.pictureOrderCountLsb,
          sps.log2MaxPictureOrderCountLsb,
          orderState,
        );
        final references = List<int>.unmodifiable(
          inspected.slice.referencePictureSet.pictures
              .map((picture) => pictureOrderCount + picture.deltaPoc),
        );
        requireH265(
          references.every((reference) => decodedPocs.contains(reference)),
          path,
          'slice references a picture outside this independently decoded unit',
        );
        requireH265(
          !decodedPocs.contains(pictureOrderCount),
          path,
          'unit contains duplicate picture-order counts',
        );
        decodedPocs.add(pictureOrderCount);
        drafts.add(
          _DraftSummary(
            decodeIndex: decodeIndex,
            pictureOrderCount: pictureOrderCount,
            key: accessUnit.key,
            randomAccess: inspected.slice.randomAccess,
            sliceType: inspected.slice.sliceType,
            temporalId: inspected.vcl.temporalId,
            referencedPictureOrderCounts: references,
            nalUnitTypes: List<int>.unmodifiable(nals.map((nal) => nal.type)),
          ),
        );
      }
      final parameterSets = activeParameterSets;
      if (parameterSets == null) {
        h265Invalid(unitPath, 'unit has no parameter sets');
      }
      final decodeToPresentation = deriveH265PresentationOrder(
        drafts
            .map((draft) => H265DecodedPictureOrder(
                  decodeIndex: draft.decodeIndex,
                  pictureOrderCount: draft.pictureOrderCount,
                ))
            .toList(),
        parameterSets.sps.maxNumReorderPics,
        '$unitPath.accessUnits',
      );
      final accessUnits = List<H265AccessUnitSummary>.unmodifiable(
        drafts.map((draft) {
          final presentationIndex =
              draft.decodeIndex < decodeToPresentation.length
                  ? decodeToPresentation[draft.decodeIndex]
                  : null;
          if (presentationIndex == null) {
            h265Invalid(unitPath, 'presentation order is incomplete');
          }
          return H265AccessUnitSummary(
            decodeIndex: draft.decodeIndex,
            presentationIndex: presentationIndex,
            pictureOrderCount: draft.pictureOrderCount,
            key: draft.key,
            randomAccess: draft.randomAccess,
            sliceType: draft.sliceType,
            temporalId: draft.temporalId,
            referencedPictureOrderCounts: draft.referencedPictureOrderCounts,
            nalUnitTypes: draft.nalUnitTypes,
          );
        }),
      );
      units.add(
        H265UnitInspection(
          id: unit.id,
          accessUnits: accessUnits,
          decodeToPresentation: decodeToPresentation,
        ),
      );
    }

    if (stableParameterSets == null) {
      h265Invalid('units', 'no HEVC parameter sets found');
    }
    final parameterSet = _createParameterSetSummary(stableParameterSets.sps);
    return H265RenditionInspection(
      parameterSet: parameterSet,
      decoderConfig: createH265VideoDecoderConfig(stableParameterSets.sps),
      units: List<H265UnitInspection>.unmodifiable(units),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.profileInvalid, 'HEVC inspection failed');
  }
}

_InspectedAccessUnit _inspectAccessUnitStructure(
  List<H265AnnexBNalUnit> nals,
  H265AccessUnitInput input,
  int decodeIndex,
  String path,
  _H265ParameterSetState? activeParameterSets,
  _H265ParameterSetState? stableParameterSets,
) {
  requireH265(
    nals.isNotEmpty && nals[0].type == H265_NAL_AUD,
    path,
    'access unit must begin with AUD',
  );
  requireH265(
    nals.where((nal) => nal.type == H265_NAL_AUD).length == 1,
    path,
    'access unit must contain exactly one AUD',
  );
  final vcl = nals.where((nal) => isH265VclNalType(nal.type)).toList();
  requireH265(
    vcl.length == 1,
    path,
    'the production HEVC profile requires one VCL NAL per access unit',
  );
  final picture = vcl[0];
  final randomAccess = isH265RandomAccessNalType(picture.type);
  requireH265(
    input.key == randomAccess,
    '$path.key',
    randomAccess
        ? 'random-access picture is missing its key assertion'
        : 'non-random-access picture has a key assertion',
  );
  requireH265(
    decodeIndex == 0 ? randomAccess : !randomAccess,
    path,
    decodeIndex == 0
        ? 'every unit must begin with a random-access picture'
        : 'random-access pictures are permitted only at unit start',
  );

  _H265ParameterSetState? parameterSets = activeParameterSets;
  if (decodeIndex == 0) {
    requireH265(
      nals.length == 5 &&
          nals[1].type == H265_NAL_VPS &&
          nals[2].type == H265_NAL_SPS &&
          nals[3].type == H265_NAL_PPS &&
          identical(nals[4], picture),
      path,
      'unit start must contain exactly AUD/VPS/SPS/PPS/VCL',
    );
    final vpsNal = nals[1];
    final spsNal = nals[2];
    final ppsNal = nals[3];
    final vps = parseH265Vps(vpsNal, '$path.vps');
    final sps = parseH265Sps(spsNal, '$path.sps');
    final pps = parseH265Pps(ppsNal, '$path.pps');
    requireH265(
      sps.videoParameterSetId == vps.id,
      path,
      'SPS references an unexpected VPS',
    );
    requireH265(pps.spsId == sps.id, path, 'PPS references an unexpected SPS');
    requireH265(
      sameH265ProfileTierLevel(vps.profileTierLevel, sps.profileTierLevel),
      path,
      'VPS and SPS profile-tier-level declarations differ',
    );
    if (stableParameterSets != null) {
      requireH265(
        vps.payloadSignature == stableParameterSets.vps.payloadSignature &&
            sps.payloadSignature == stableParameterSets.sps.payloadSignature &&
            pps.payloadSignature == stableParameterSets.pps.payloadSignature,
        path,
        'HEVC parameter-set bytes changed within the rendition',
      );
    }
    parameterSets = _H265ParameterSetState(vps: vps, sps: sps, pps: pps);
  } else {
    requireH265(
      nals.length == 2 && identical(nals[1], picture),
      path,
      'later access units must contain exactly AUD/VCL',
    );
  }
  if (parameterSets == null) {
    h265Invalid(path, 'access unit has no parameter sets');
  }
  final audPictureType = _parseAud(nals[0], '$path.aud');
  final slice = parseH265SliceHeader(
    picture,
    parameterSets.pps,
    parameterSets.sps,
    '$path.slice',
  );
  requireH265(
    (slice.sliceType == 'I' && audPictureType >= 0) ||
        (slice.sliceType == 'P' && audPictureType >= 1) ||
        (slice.sliceType == 'B' && audPictureType == 2),
    '$path.aud',
    'AUD pic_type does not permit the coded slice type',
  );
  return _InspectedAccessUnit(
    parameterSets: parameterSets,
    vcl: picture,
    slice: slice,
  );
}

void _validateParameterSetsAgainstProfile(
  _H265ParameterSetState state,
  H265MainProfile profile,
  String path,
) {
  final sps = state.sps;
  final ptl = sps.profileTierLevel;
  requireH265(
    ptl.profileSpace == 0 &&
        ptl.profileIdc == 1 &&
        (ptl.profileCompatibilityFlags & 0x02) != 0,
    '$path.sps',
    'the production HEVC profile requires Main profile compatibility',
  );
  final firstConstraintByte = ptl.constraintIndicatorFlags.isNotEmpty
      ? ptl.constraintIndicatorFlags[0]
      : 0;
  requireH265(
    (firstConstraintByte & 0x80) != 0 &&
        (firstConstraintByte & 0x40) == 0 &&
        (firstConstraintByte & 0x10) != 0,
    '$path.sps',
    'HEVC must signal progressive, frame-only source constraints',
  );
  requireH265(
    sps.codedWidth == profile.codedWidth &&
        sps.codedHeight == profile.codedHeight,
    '$path.sps',
    'SPS coded dimensions do not match the rendition profile',
  );
  final expected = profile.expectedVisibleRect ??
      [0, 0, profile.codedWidth, profile.codedHeight];
  requireH265(
    sps.crop.left == expected[0] &&
        sps.crop.top == expected[1] &&
        sps.crop.visibleWidth == expected[2] &&
        sps.crop.visibleHeight == expected[3] &&
        sps.crop.right == profile.codedWidth - expected[2] &&
        sps.crop.bottom == profile.codedHeight - expected[3],
    '$path.sps',
    'SPS conformance crop does not match the rendition profile',
  );
  requireH265(
    sps.squareSampleAspect,
    '$path.sps',
    'square sample aspect is required',
  );
  requireH265(
    !sps.defaultDisplayWindowPresent,
    '$path.sps',
    'default-display-window cropping is forbidden',
  );
  requireH265(sps.timing != null, '$path.sps', 'SPS VUI timing is required');
  requireH265(
    BigInt.from(sps.timing!.timeScale) *
            BigInt.from(profile.frameRate.denominator) ==
        BigInt.from(sps.timing!.numUnitsInTick) *
            BigInt.from(profile.frameRate.numerator),
    '$path.sps',
    'SPS VUI timing does not match the rendition frame rate',
  );
  requireH265(
    !sps.color.fullRange &&
        sps.color.colourPrimaries == 1 &&
        sps.color.transferCharacteristics == 1 &&
        sps.color.matrixCoefficients == 1,
    '$path.sps',
    'the production HEVC profile requires BT.709 limited-range colour signalling',
  );
  requireH265(
    !sps.longTermReferencePicturesPresent,
    '$path.sps',
    'long-term HEVC references are outside the production profile',
  );
}

H265MainProfile _cloneH265Profile(H265MainProfile profile) {
  _positiveInteger(profile.codedWidth, 'profile.codedWidth');
  _positiveInteger(profile.codedHeight, 'profile.codedHeight');
  requireH265(
    profile.codedWidth % 2 == 0 && profile.codedHeight % 2 == 0,
    'profile',
    '4:2:0 HEVC coded dimensions must be even',
  );
  _positiveInteger(profile.frameRate.numerator, 'profile.frameRate.numerator');
  _positiveInteger(
    profile.frameRate.denominator,
    'profile.frameRate.denominator',
  );
  requireH265(
    profile.requireBt709LimitedRange == true,
    'profile.requireBt709LimitedRange',
    'the production HEVC profile requires BT.709 limited range',
  );
  final expectedVisibleRect = profile.expectedVisibleRect == null
      ? null
      : _cloneVisibleRect(
          profile.expectedVisibleRect!,
          profile.codedWidth,
          profile.codedHeight,
        );
  return H265MainProfile(
    codedWidth: profile.codedWidth,
    codedHeight: profile.codedHeight,
    expectedVisibleRect: expectedVisibleRect,
    frameRate: profile.frameRate,
    requireBt709LimitedRange: true,
  );
}

List<int> _cloneVisibleRect(
  List<int> value,
  int codedWidth,
  int codedHeight,
) {
  requireH265(
    value.length == 4 && value[0] == 0 && value[1] == 0,
    'profile.expectedVisibleRect',
    'expected visible rectangle must begin at the coded origin',
  );
  _positiveInteger(value[2], 'profile.expectedVisibleRect[2]', codedWidth);
  _positiveInteger(value[3], 'profile.expectedVisibleRect[3]', codedHeight);
  requireH265(
    value[2] % 2 == 0 && value[3] % 2 == 0,
    'profile.expectedVisibleRect',
    '4:2:0 visible dimensions must be even',
  );
  return List.unmodifiable([0, 0, value[2], value[3]]);
}

void _validateAccessUnitInput(H265AccessUnitInput input, String path) {
  requireH265(
    input.bytes.length <= H265_MAX_ACCESS_UNIT_BYTES,
    '$path.bytes',
    'access unit exceeds the HEVC byte budget',
  );
}

int _parseAud(H265AnnexBNalUnit nal, String path) {
  final reader = H265RbspBitReader(nal.rbsp, path, nal.offset + 2);
  final pictureType = reader.readBits(3, 'pic_type');
  requireH265(pictureType <= 2, path, 'AUD pic_type is reserved');
  reader.readTrailingBits();
  return pictureType;
}

H265ParameterSetSummary _createParameterSetSummary(ParsedH265Sps sps) {
  return H265ParameterSetSummary(
    profileTierLevel: sps.profileTierLevel,
    codec: h265CodecString(sps.profileTierLevel),
    codedWidth: sps.codedWidth,
    codedHeight: sps.codedHeight,
    crop: sps.crop,
    maxNumReorderPics: sps.maxNumReorderPics,
    maxDecPicBuffering: sps.maxDecPicBuffering,
    color: sps.color,
  );
}

void _positiveInteger(int value, String path, [int? maximum]) {
  requireH265(
    value > 0 &&
        value <= maxSafeInteger &&
        (maximum == null || value <= maximum),
    path,
    maximum == null
        ? 'must be a positive safe integer'
        : 'must be a positive safe integer no greater than $maximum',
  );
}
