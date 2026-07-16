/// Sole rendition -> unit -> frame sample-ordinal traversal for version 0.1.
///
/// Dart port of `packages/format/src/sample-plan.ts`.
library;

import 'checked_integer.dart' show checkedAdd;
import 'errors.dart';
import 'model.dart' show UnitV01;

const int _uint32Max = 0xffffffff;

class PlanRendition {
  const PlanRendition({required this.id, required this.profile});

  final String id;
  final String profile;
}

class PlanUnit {
  const PlanUnit({required this.id, required this.frameCount});

  final String id;
  final int frameCount;
}

class CanonicalSampleSlot {
  const CanonicalSampleSlot({
    required this.ordinal,
    required this.renditionIndex,
    required this.renditionId,
    required this.unitIndex,
    required this.unitId,
    required this.frameIndex,
    required this.keyRequired,
  });

  final int ordinal;
  final int renditionIndex;
  final String renditionId;
  final int unitIndex;
  final String unitId;
  final int frameIndex;
  final bool keyRequired;
}

class CanonicalSampleSpan {
  const CanonicalSampleSpan({
    required this.renditionIndex,
    required this.renditionId,
    required this.unitIndex,
    required this.unitId,
    required this.sampleStart,
    required this.sampleCount,
    required this.keyEveryFrame,
  });

  final int renditionIndex;
  final String renditionId;
  final int unitIndex;
  final String unitId;
  final int sampleStart;
  final int sampleCount;
  final bool keyEveryFrame;
}

class CanonicalSamplePlan {
  const CanonicalSamplePlan({
    required this.renditionCount,
    required this.unitCount,
    required this.totalFrameCount,
    required this.recordCount,
    required this.spans,
    required this.unitSpans,
    required CanonicalSampleSlot Function(int index) recordAt,
  }) : _recordAt = recordAt;

  final int renditionCount;
  final int unitCount;
  final int totalFrameCount;
  final int recordCount;
  final List<CanonicalSampleSpan> spans;
  final List<List<CanonicalSampleSpan>> unitSpans;
  final CanonicalSampleSlot Function(int index) _recordAt;

  CanonicalSampleSlot recordAt(int index) => _recordAt(index);

  Iterable<CanonicalSampleSlot> records() sync* {
    for (final span in spans) {
      for (var frameIndex = 0; frameIndex < span.sampleCount; frameIndex += 1) {
        yield CanonicalSampleSlot(
          ordinal: span.sampleStart + frameIndex,
          renditionIndex: span.renditionIndex,
          renditionId: span.renditionId,
          unitIndex: span.unitIndex,
          unitId: span.unitId,
          frameIndex: frameIndex,
          keyRequired: frameIndex == 0 || span.keyEveryFrame,
        );
      }
    }
  }
}

/// Owns the sole rendition -> unit -> frame traversal for version 0.1.
CanonicalSamplePlan createCanonicalSamplePlan(
  List<PlanRendition> renditions,
  List<PlanUnit> units,
  int maximumRecords, [
  int? maximumTotalFramesArg,
]) {
  final maximumTotalFrames = maximumTotalFramesArg ?? maximumRecords;
  if (maximumRecords < 0) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      'maximum sample records must be a nonnegative safe integer',
    );
  }
  if (maximumTotalFrames < 0) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      'maximum total frames must be a nonnegative safe integer',
    );
  }
  if (renditions.isEmpty) {
    throw FormatError(
      FormatErrorCode.manifestInvalid,
      'at least one rendition is required',
      const FormatErrorDetails(path: 'renditions'),
    );
  }
  if (renditions.length > maximumRecords) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'rendition count cannot fit the sample record budget',
      const FormatErrorDetails(path: 'renditions'),
    );
  }
  if (units.isEmpty) {
    throw FormatError(
      FormatErrorCode.manifestInvalid,
      'at least one unit is required',
      const FormatErrorDetails(path: 'units'),
    );
  }
  if (units.length > (maximumRecords < maximumTotalFrames ? maximumRecords : maximumTotalFrames)) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'unit count cannot fit the sample record budget',
      const FormatErrorDetails(path: 'units'),
    );
  }
  var totalFrameCount = 0;
  for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
    final unit = units[unitIndex];
    if (unit.frameCount <= 0) {
      throw FormatError(
        FormatErrorCode.manifestInvalid,
        'units[$unitIndex].frameCount must be a positive safe integer',
        FormatErrorDetails(path: 'units[$unitIndex].frameCount'),
      );
    }
    final nextTotalFrameCount = totalFrameCount + unit.frameCount;
    if (nextTotalFrameCount > _uint32Max) {
      throw FormatError(
        FormatErrorCode.integerUnsafe,
        'total unit frames cannot fit the uint32 sample-index representation',
      );
    }
    if (nextTotalFrameCount > maximumTotalFrames) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'total unit frames exceed the active budget',
      );
    }
    totalFrameCount = nextTotalFrameCount;
  }
  final recordCountBigInt = BigInt.from(totalFrameCount) * BigInt.from(renditions.length);
  if (recordCountBigInt > BigInt.from(_uint32Max)) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      'sample record count cannot fit the uint32 sample-index representation',
    );
  }
  final recordCount = recordCountBigInt.toInt();
  if (recordCount > maximumRecords) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'sample record count exceeds the active budget',
    );
  }

  final spans = <CanonicalSampleSpan>[];
  final unitSpans = List<List<CanonicalSampleSpan>>.generate(units.length, (_) => []);
  var ordinal = 0;
  for (var renditionIndex = 0; renditionIndex < renditions.length; renditionIndex += 1) {
    final rendition = renditions[renditionIndex];
    for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
      final unit = units[unitIndex];
      final span = CanonicalSampleSpan(
        renditionIndex: renditionIndex,
        renditionId: rendition.id,
        unitIndex: unitIndex,
        unitId: unit.id,
        sampleStart: ordinal,
        sampleCount: unit.frameCount,
        keyEveryFrame: rendition.profile == 'reference-rgba-v0',
      );
      spans.add(span);
      unitSpans[unitIndex].add(span);
      ordinal = checkedAdd(ordinal, unit.frameCount, recordCount, 'sample span end');
    }
  }
  if (ordinal != recordCount) {
    throw FormatError(FormatErrorCode.integerUnsafe, 'canonical sample count drifted');
  }

  CanonicalSampleSlot recordAt(int index) {
    if (index < 0 || index >= recordCount) {
      throw FormatError(
        FormatErrorCode.integerUnsafe,
        'sample record index is outside the canonical plan',
      );
    }
    var lower = 0;
    var upper = spans.length - 1;
    while (lower <= upper) {
      final middle = lower + ((upper - lower) ~/ 2);
      final span = spans[middle];
      if (index < span.sampleStart) {
        upper = middle - 1;
        continue;
      }
      final spanEnd = checkedAdd(span.sampleStart, span.sampleCount, recordCount, 'sample span end');
      if (index >= spanEnd) {
        lower = middle + 1;
        continue;
      }
      final frameIndex = index - span.sampleStart;
      return CanonicalSampleSlot(
        ordinal: index,
        renditionIndex: span.renditionIndex,
        renditionId: span.renditionId,
        unitIndex: span.unitIndex,
        unitId: span.unitId,
        frameIndex: frameIndex,
        keyRequired: frameIndex == 0 || span.keyEveryFrame,
      );
    }
    throw FormatError(FormatErrorCode.integerUnsafe, 'canonical sample span lookup failed');
  }

  return CanonicalSamplePlan(
    renditionCount: renditions.length,
    unitCount: units.length,
    totalFrameCount: totalFrameCount,
    recordCount: recordCount,
    spans: spans,
    unitSpans: unitSpans,
    recordAt: recordAt,
  );
}

/// Assert that on-wire span descriptors exactly match a canonical plan.
///
/// [units] is the real production `List<UnitV01>` (TS `readonly
/// Pick<UnitV01, "samples">[]`); only `.samples` is read.
void validateCanonicalSampleSpans(
  CanonicalSamplePlan plan,
  List<UnitV01> units, [
  FormatErrorCode code = FormatErrorCode.manifestInvalid,
]) {
  for (final expected in plan.spans) {
    final unit = expected.unitIndex < units.length ? units[expected.unitIndex] : null;
    final span = unit != null && expected.renditionIndex < unit.samples.length
        ? unit.samples[expected.renditionIndex]
        : null;
    if (span == null ||
        span.rendition != expected.renditionId ||
        span.sampleStart != expected.sampleStart ||
        span.sampleCount != expected.sampleCount) {
      throw FormatError(
        code,
        'unit ${expected.unitId} sample span does not match canonical ordinals',
        FormatErrorDetails(
          path: 'units[${expected.unitIndex}].samples[${expected.renditionIndex}]',
        ),
      );
    }
  }
  for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
    final unit = units[unitIndex];
    final expectedCount = plan.renditionCount;
    if (unit.samples.length != expectedCount) {
      throw FormatError(
        code,
        'unit $unitIndex must declare exactly $expectedCount sample spans',
        FormatErrorDetails(path: 'units[$unitIndex].samples'),
      );
    }
  }
}
