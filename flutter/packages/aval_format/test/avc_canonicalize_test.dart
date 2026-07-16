/// Dart port of `packages/format/test/avc-canonicalize.test.ts`.
library;

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

import 'avc_fixture.dart';

void main() {
  group('AVC constraint_set2 canonicalization', () {
    test('rewrites only C0 to E0 and then passes the strict final profile', () {
      final input = validInspectionInput(
        spsOptions: const SpsFixtureOptions(compatibility: 0xc0),
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));

      final before = input.units[0].accessUnits[0].bytes.sublist(0);
      for (final unit in input.units) {
        for (final accessUnit in unit.accessUnits) {
          accessUnit.bytes = canonicalizeAvcConstraintSet2(accessUnit.bytes);
        }
      }
      final after = input.units[0].accessUnits[0].bytes;
      final changedOffsets = <int>[];
      for (var index = 0; index < before.length; index += 1) {
        if (before[index] != after[index]) {
          changedOffsets.add(index);
        }
      }

      expect(changedOffsets, hasLength(1));
      expect(before[changedOffsets[0]], 0xc0);
      expect(after[changedOffsets[0]], 0xe0);
      expect(
        inspectAvcAnnexBRendition(input.toInspectionInput()).parameterSet.constraintSet2,
        isTrue,
      );
    });

    test('is byte-idempotent for E0 and always returns fresh bytes', () {
      final source = makeSps(const SpsFixtureOptions(compatibility: 0xe0));
      final canonical = canonicalizeAvcConstraintSet2(source);
      expect(canonical, equals(source));
      expect(identical(canonical, source), isFalse);
    });

    test('promotes libx264 Level 1b D0 to canonical Level 1.1 E0', () {
      final input = validInspectionInput(
        spsOptions: const SpsFixtureOptions(compatibility: 0xd0, levelIdc: 11),
      );
      input.profile.averageBitrate = 80000;
      input.profile.peakBitrate = 100000;
      input.profile.cpbBufferBits = 100000;

      expect(
        () => inspectAvcAnnexBEncoderCandidateRendition(input.toInspectionInput()),
        returnsNormally,
      );
      _expectProfileError(() => inspectAvcAnnexBRendition(input.toInspectionInput()));
      for (final unit in input.units) {
        for (final accessUnit in unit.accessUnits) {
          accessUnit.bytes = canonicalizeAvcConstraintSet2(accessUnit.bytes);
        }
      }

      final parameterSet =
          inspectAvcAnnexBRendition(input.toInspectionInput()).parameterSet;
      expect(parameterSet.levelIdc, 11);
      expect(parameterSet.constraintSet2, isTrue);
    });

    test('rejects a malformed SPS instead of performing an unchecked byte patch', () {
      final malformed = makeSps();
      malformed[malformed.length - 1] = 0;
      _expectProfileError(() => canonicalizeAvcConstraintSet2(malformed));
    });
  });
}

void _expectProfileError(void Function() callback) {
  expect(callback, throwsA(isA<FormatError>()));
  try {
    callback();
    fail('expected a FormatError');
  } on FormatError catch (error) {
    expect(error.code, FormatErrorCode.profileInvalid);
  }
}
