/// Converts bounded raw FFmpeg Annex B output into the one canonical H264
/// runtime form.
///
/// SEI is the sole encoder-only NAL type tolerated, and it is removed before
/// either candidate or strict inspection.
///
/// Dart port of `packages/format/src/h264/encoder-preparation.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../constants.dart' show formatDefaultBudgets, identifierPattern;
import '../errors.dart';
import 'annex_b.dart';
import 'failure.dart';
import 'inspector.dart' show cloneH264Profile, inspectH264AnnexBRendition;
import 'types.dart';

const int _maxEncoderNalUnitsPerAccessUnit = 4;
const int _maxEncoderParameterSetNalUnits = 2;
const List<int> _fourByteStartCode = [0, 0, 0, 1];

/// Converts bounded raw FFmpeg output into the one canonical H264 runtime form.
/// SEI is the sole encoder-only NAL type tolerated, and it is removed before
/// either candidate or strict inspection.
H264EncoderRenditionPreparation prepareH264EncoderRendition(
  H264EncoderRenditionPreparationInput input,
) {
  try {
    final profile = cloneH264Profile(input.profile);
    requireH264(input.units.isNotEmpty, 'units', 'at least one unit is required');
    requireH264(
      input.units.length <= formatDefaultBudgets.maxUnits,
      'units',
      'unit count exceeds the format budget',
    );

    final normalizedUnits = <H264UnitInput>[];
    final unitIds = <String>{};
    var totalRawBytes = 0;
    var totalAccessUnits = 0;
    for (var index = 0; index < input.units.length; index += 1) {
      final unit = input.units[index];
      final path = 'units[$index]';
      requireH264(
        identifierPattern.hasMatch(unit.id),
        '$path.id',
        'unit id is invalid',
      );
      requireH264(!unitIds.contains(unit.id), '$path.id', 'unit id is duplicated');
      unitIds.add(unit.id);
      requireH264(unit.bytes.isNotEmpty, '$path.bytes', 'raw unit stream is empty');
      requireH264(
        unit.expectedAccessUnitCount > 0 &&
            unit.expectedAccessUnitCount <= maxSafeInteger,
        '$path.expectedAccessUnitCount',
        'expected access-unit count must be a positive safe integer',
      );
      totalRawBytes += unit.bytes.length;
      totalAccessUnits += unit.expectedAccessUnitCount;
      requireH264(
        totalRawBytes <= maxSafeInteger &&
            totalRawBytes <= formatDefaultBudgets.maxFileBytes,
        '$path.bytes',
        'raw rendition bytes exceed the compiled-file budget',
      );
      requireH264(
        totalAccessUnits <= maxSafeInteger &&
            totalAccessUnits <= formatDefaultBudgets.maxTotalUnitFrames,
        '$path.expectedAccessUnitCount',
        'total access-unit count exceeds the format budget',
      );

      normalizedUnits.add(
        H264UnitInput(
          id: unit.id,
          accessUnits: _normalizeEncoderUnitStream(
            unit.bytes,
            unit.expectedAccessUnitCount,
            '$path.bytes',
          ),
        ),
      );
    }
    final canonicalUnits = List<H264UnitInput>.unmodifiable(normalizedUnits);
    final inspection = inspectH264AnnexBRendition(
      H264RenditionInspectionInput(profile: profile, units: canonicalUnits),
    );
    return H264EncoderRenditionPreparation(
      units: canonicalUnits,
      inspection: inspection,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'H264 encoder rendition could not be prepared',
    );
  }
}

List<H264AccessUnitInput> _normalizeEncoderUnitStream(
  Uint8List bytes,
  int expectedAccessUnitCount,
  String path,
) {
  final maximumNalUnits = expectedAccessUnitCount *
          _maxEncoderNalUnitsPerAccessUnit +
      _maxEncoderParameterSetNalUnits;
  requireH264(
    maximumNalUnits <= maxSafeInteger,
    path,
    'derived encoder NAL-unit budget is not representable',
  );
  final nals = splitAnnexBAccessUnit(bytes, path, maximumNalUnits, true);
  requireH264(
    nals.isNotEmpty && nals[0].type == H264_NAL_TYPE_AUD,
    path,
    'raw encoder stream must begin with AUD',
  );

  final groups = <List<AnnexBNalUnit>>[];
  List<AnnexBNalUnit>? current;
  for (final nal in nals) {
    if (nal.type == H264_NAL_TYPE_AUD) {
      if (current != null) {
        groups.add(current);
      }
      current = <AnnexBNalUnit>[nal];
    } else {
      requireH264(current != null, path, 'NAL unit appears before the first AUD');
      current!.add(nal);
    }
  }
  if (current != null) {
    groups.add(current);
  }
  requireH264(
    groups.length == expectedAccessUnitCount,
    path,
    'expected $expectedAccessUnitCount access units but found ${groups.length}',
  );

  return List.unmodifiable([
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex += 1)
      _normalizeEncoderAccessUnit(
        groups[groupIndex],
        '$path.accessUnits[$groupIndex]',
      ),
  ]);
}

H264AccessUnitInput _normalizeEncoderAccessUnit(
  List<AnnexBNalUnit> group,
  String path,
) {
  final retained =
      group.where((nal) => nal.type != H264_NAL_TYPE_SEI).toList();
  requireH264(
    retained.isNotEmpty && retained[0].type == H264_NAL_TYPE_AUD,
    path,
    'normalized access unit must begin with AUD',
  );
  final vcl = retained
      .where(
        (nal) =>
            nal.type == H264_NAL_TYPE_IDR || nal.type == H264_NAL_TYPE_NON_IDR,
      )
      .toList();
  requireH264(vcl.isNotEmpty, path, 'access unit contains no coded picture');

  var length = 0;
  for (final nal in retained) {
    length += _fourByteStartCode.length + nal.payload.length;
    requireH264(
      length <= maxSafeInteger && length <= formatDefaultBudgets.maxChunkBytes,
      path,
      'normalized access unit exceeds the sample budget',
    );
  }
  Uint8List normalized;
  try {
    normalized = Uint8List(length);
  } catch (_) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'normalized H264 access-unit allocation of $length bytes failed',
      FormatErrorDetails(path: path),
    );
  }
  var offset = 0;
  for (final nal in retained) {
    normalized.setRange(
      offset,
      offset + _fourByteStartCode.length,
      _fourByteStartCode,
    );
    offset += _fourByteStartCode.length;
    normalized.setRange(offset, offset + nal.payload.length, nal.payload);
    offset += nal.payload.length;
  }
  return H264AccessUnitInput(
    key: vcl.any((nal) => nal.type == H264_NAL_TYPE_IDR),
    bytes: normalized,
  );
}
