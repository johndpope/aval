/// Canonicalizes libx264's valid `42 C0 xx` and Level-1b `42 D0 0B` SPS
/// declarations to the format's `42 E0 xx` Constrained Baseline declaration.
///
/// Dart port of `packages/format/src/avc/canonicalize.ts`.
library;

import 'dart:typed_data';

import '../constants.dart' show formatDefaultBudgets;
import '../errors.dart';
import 'annex_b.dart' show AVC_NAL_TYPE_SPS, splitAnnexBAccessUnit;
import 'failure.dart';
import 'parameter_sets.dart' show parseSps;

const int _constrainedBaselineC0 = 0xc0;
const int _constrainedBaselineLevel1bD0 = 0xd0;
const int _constrainedBaselineE0 = 0xe0;

/// The authored level byte is preserved; Level 1b is promoted to Level 1.1.
/// Each SPS is fully parsed both before and after the rewrite.
Uint8List canonicalizeAvcConstraintSet2(Uint8List accessUnitBytes) {
  const path = 'accessUnit';
  requireAvc(
    accessUnitBytes.length <= formatDefaultBudgets.maxSampleBytes,
    path,
    'access unit exceeds the sample budget',
  );
  final nals = splitAnnexBAccessUnit(accessUnitBytes, path);
  Uint8List output;
  try {
    output = Uint8List.fromList(accessUnitBytes);
  } catch (_) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AVC canonicalization allocation of ${accessUnitBytes.lengthInBytes} bytes failed',
      FormatErrorDetails(path: path),
    );
  }
  for (var index = 0; index < nals.length; index += 1) {
    final nal = nals[index];
    if (nal.type != AVC_NAL_TYPE_SPS) {
      continue;
    }
    final nalPath = '$path.nals[$index]';
    parseSps(nal, nalPath, 'encoder-candidate');
    final compatibilityOffset = nal.offset + 2;
    final compatibility = output[compatibilityOffset];
    requireAvc(
      compatibility == _constrainedBaselineC0 ||
          compatibility == _constrainedBaselineLevel1bD0 ||
          compatibility == _constrainedBaselineE0,
      nalPath,
      'only an SPS C0/D0 to E0 constraint canonicalization is permitted',
      compatibilityOffset,
    );
    output[compatibilityOffset] = _constrainedBaselineE0;
  }

  // Re-tokenize and parse rewritten SPS bytes so the helper cannot emit
  // syntax that the strict final-profile inspector would reject.
  final rewrittenNals = splitAnnexBAccessUnit(output, path);
  for (var index = 0; index < rewrittenNals.length; index += 1) {
    final nal = rewrittenNals[index];
    if (nal.type == AVC_NAL_TYPE_SPS) {
      final parsed = parseSps(nal, '$path.nals[$index]');
      requireAvc(
        parsed.constraintSet2,
        '$path.nals[$index]',
        'rewritten SPS does not assert constraint_set2',
      );
    }
  }
  return output;
}
