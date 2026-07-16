/// Converts bounded raw FFmpeg Annex B output into the one canonical AVC
/// runtime form.
///
/// SEI is the sole encoder-only NAL type tolerated, and it is removed before
/// either candidate or strict inspection.
///
/// Dart port of `packages/format/src/avc/encoder-preparation.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../constants.dart' show formatDefaultBudgets, identifierPattern;
import '../errors.dart';
import 'annex_b.dart';
import 'canonicalize.dart' show canonicalizeAvcConstraintSet2;
import 'failure.dart';
import 'inspector.dart'
    show
        cloneAvcProfile,
        inspectAvcAnnexBEncoderCandidateRendition,
        inspectAvcAnnexBRendition;
import 'types.dart';

const int _maxEncoderNalUnitsPerAccessUnit = 4;
const int _maxEncoderParameterSetNalUnits = 2;
const List<int> _fourByteStartCode = [0, 0, 0, 1];

AvcEncoderRenditionPreparation prepareAvcEncoderRendition(
  AvcEncoderRenditionPreparationInput input,
) {
  try {
    final profile = cloneAvcProfile(input.profile);
    requireAvc(input.units.isNotEmpty, 'units', 'at least one unit is required');
    requireAvc(
      input.units.length <= formatDefaultBudgets.maxUnits,
      'units',
      'unit count exceeds the format budget',
    );

    final normalizedUnits = <AvcUnitInput>[];
    final unitIds = <String>{};
    var totalRawBytes = 0;
    var totalAccessUnits = 0;
    for (var index = 0; index < input.units.length; index += 1) {
      final unit = input.units[index];
      final path = 'units[$index]';
      requireAvc(
        identifierPattern.hasMatch(unit.id),
        '$path.id',
        'unit id is invalid',
      );
      requireAvc(!unitIds.contains(unit.id), '$path.id', 'unit id is duplicated');
      unitIds.add(unit.id);
      requireAvc(unit.bytes.isNotEmpty, '$path.bytes', 'raw unit stream is empty');
      requireAvc(
        unit.expectedAccessUnitCount > 0 &&
            unit.expectedAccessUnitCount <= maxSafeInteger,
        '$path.expectedAccessUnitCount',
        'expected access-unit count must be a positive safe integer',
      );
      totalRawBytes += unit.bytes.length;
      totalAccessUnits += unit.expectedAccessUnitCount;
      requireAvc(
        totalRawBytes <= formatDefaultBudgets.maxFileBytes,
        '$path.bytes',
        'raw rendition bytes exceed the compiled-file budget',
      );
      requireAvc(
        totalAccessUnits <= formatDefaultBudgets.maxTotalUnitFrames,
        '$path.expectedAccessUnitCount',
        'total access-unit count exceeds the format budget',
      );

      normalizedUnits.add(
        AvcUnitInput(
          id: unit.id,
          accessUnits: _normalizeEncoderUnitStream(
            unit.bytes,
            unit.expectedAccessUnitCount,
            '$path.bytes',
          ),
        ),
      );
    }
    final candidateUnits = List<AvcUnitInput>.unmodifiable(normalizedUnits);
    inspectAvcAnnexBEncoderCandidateRendition(
      AvcRenditionInspectionInput(profile: profile, units: candidateUnits),
    );

    final canonicalizations = <AvcUnitCanonicalization>[];
    final canonicalUnits = <AvcUnitInput>[];
    for (final unit in candidateUnits) {
      var constraintSet2Canonicalized = false;
      final accessUnits = <AvcAccessUnitInput>[];
      for (final accessUnit in unit.accessUnits) {
        final bytes = canonicalizeAvcConstraintSet2(accessUnit.bytes);
        if (!_bytesEqual(bytes, accessUnit.bytes)) {
          constraintSet2Canonicalized = true;
        }
        accessUnits.add(AvcAccessUnitInput(key: accessUnit.key, bytes: bytes));
      }
      canonicalUnits.add(
        AvcUnitInput(id: unit.id, accessUnits: List.unmodifiable(accessUnits)),
      );
      canonicalizations.add(
        AvcUnitCanonicalization(
          unitId: unit.id,
          constraintSet2Canonicalized: constraintSet2Canonicalized,
        ),
      );
    }
    final frozenCanonicalUnits = List<AvcUnitInput>.unmodifiable(canonicalUnits);
    final inspection = inspectAvcAnnexBRendition(
      AvcRenditionInspectionInput(
        profile: profile,
        units: frozenCanonicalUnits,
      ),
    );
    return AvcEncoderRenditionPreparation(
      units: frozenCanonicalUnits,
      inspection: inspection,
      canonicalizations: List.unmodifiable(canonicalizations),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AVC encoder rendition could not be prepared',
    );
  }
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<AvcAccessUnitInput> _normalizeEncoderUnitStream(
  Uint8List bytes,
  int expectedAccessUnitCount,
  String path,
) {
  final maximumNalUnits = expectedAccessUnitCount *
          _maxEncoderNalUnitsPerAccessUnit +
      _maxEncoderParameterSetNalUnits;
  requireAvc(
    maximumNalUnits <= maxSafeInteger,
    path,
    'derived encoder NAL-unit budget is not representable',
  );
  final nals = splitAnnexBAccessUnit(bytes, path, maximumNalUnits, true);
  requireAvc(
    nals.isNotEmpty && nals[0].type == AVC_NAL_TYPE_AUD,
    path,
    'raw encoder stream must begin with AUD',
  );

  final groups = <List<AnnexBNalUnit>>[];
  List<AnnexBNalUnit>? current;
  for (final nal in nals) {
    if (nal.type == AVC_NAL_TYPE_AUD) {
      if (current != null) {
        groups.add(current);
      }
      current = <AnnexBNalUnit>[nal];
    } else {
      requireAvc(current != null, path, 'NAL unit appears before the first AUD');
      current!.add(nal);
    }
  }
  if (current != null) {
    groups.add(current);
  }
  requireAvc(
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

AvcAccessUnitInput _normalizeEncoderAccessUnit(
  List<AnnexBNalUnit> group,
  String path,
) {
  final retained =
      group.where((nal) => nal.type != AVC_NAL_TYPE_SEI).toList();
  requireAvc(
    retained.isNotEmpty && retained[0].type == AVC_NAL_TYPE_AUD,
    path,
    'normalized access unit must begin with AUD',
  );
  final vcl = retained
      .where(
        (nal) => nal.type == AVC_NAL_TYPE_IDR || nal.type == AVC_NAL_TYPE_NON_IDR,
      )
      .toList();
  requireAvc(vcl.isNotEmpty, path, 'access unit contains no coded picture');

  var length = 0;
  for (final nal in retained) {
    length += _fourByteStartCode.length + nal.payload.length;
    requireAvc(
      length <= formatDefaultBudgets.maxSampleBytes,
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
      'normalized AVC access-unit allocation of $length bytes failed',
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
  return AvcAccessUnitInput(
    key: vcl.any((nal) => nal.type == AVC_NAL_TYPE_IDR),
    bytes: normalized,
  );
}
