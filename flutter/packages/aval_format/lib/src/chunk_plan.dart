/// Canonical rendition -> unit -> decode-order chunk plan.
///
/// Dart port of `packages/format/src/chunk-plan.ts`.
library;

import 'dart:convert' show jsonEncode;

import 'checked_integer.dart' show checkedAdd, maxSafeInteger;
import 'errors.dart';
import 'model.dart' show ProductionRendition, Unit, UnitChunkSpan;

const int _uint32Max = 0xffffffff;

class CanonicalChunkSlot {
  const CanonicalChunkSlot({
    required this.ordinal,
    required this.renditionIndex,
    required this.renditionId,
    required this.unitIndex,
    required this.unitId,
    required this.decodeIndex,
    required this.randomAccessRequired,
  });

  final int ordinal;
  final int renditionIndex;
  final String renditionId;
  final int unitIndex;
  final String unitId;
  final int decodeIndex;
  final bool randomAccessRequired;
}

class CanonicalChunkSpan {
  const CanonicalChunkSpan({
    required this.renditionIndex,
    required this.renditionId,
    required this.unitIndex,
    required this.unitId,
    required this.chunkStart,
    required this.chunkCount,
    required this.frameCount,
  });

  final int renditionIndex;
  final String renditionId;
  final int unitIndex;
  final String unitId;
  final int chunkStart;
  final int chunkCount;
  final int frameCount;
}

class CanonicalChunkPlan {
  const CanonicalChunkPlan({
    required this.renditionCount,
    required this.unitCount,
    required this.totalFrameCount,
    required this.recordCount,
    required this.spans,
    required this.unitSpans,
  });

  final int renditionCount;
  final int unitCount;
  final int totalFrameCount;
  final int recordCount;
  final List<CanonicalChunkSpan> spans;
  final List<List<CanonicalChunkSpan>> unitSpans;

  CanonicalChunkSlot recordAt(int index) {
    if (index < 0 || index > maxSafeInteger || index >= recordCount) {
      throw FormatError(FormatErrorCode.integerUnsafe,
          'chunk record index is outside the canonical plan');
    }
    var low = 0;
    var high = spans.length - 1;
    while (low <= high) {
      final middle = low + ((high - low) ~/ 2);
      final span = spans[middle];
      if (index < span.chunkStart) {
        high = middle - 1;
      } else if (index >= span.chunkStart + span.chunkCount) {
        low = middle + 1;
      } else {
        final decodeIndex = index - span.chunkStart;
        return CanonicalChunkSlot(
          ordinal: index,
          renditionIndex: span.renditionIndex,
          renditionId: span.renditionId,
          unitIndex: span.unitIndex,
          unitId: span.unitId,
          decodeIndex: decodeIndex,
          randomAccessRequired: decodeIndex == 0,
        );
      }
    }
    throw FormatError(
        FormatErrorCode.integerUnsafe, 'canonical chunk span lookup failed');
  }

  Iterable<CanonicalChunkSlot> records() sync* {
    for (final span in spans) {
      for (var decodeIndex = 0; decodeIndex < span.chunkCount; decodeIndex += 1) {
        yield CanonicalChunkSlot(
          ordinal: span.chunkStart + decodeIndex,
          renditionIndex: span.renditionIndex,
          renditionId: span.renditionId,
          unitIndex: span.unitIndex,
          unitId: span.unitId,
          decodeIndex: decodeIndex,
          randomAccessRequired: decodeIndex == 0,
        );
      }
    }
  }
}

/// Own the sole rendition -> unit -> decode-order chunk traversal.
CanonicalChunkPlan createCanonicalChunkPlan(
  List<ProductionRendition> renditions,
  List<Unit> units,
  int maximumRecords, [
  int? maximumTotalFrames,
]) {
  final maxTotalFrames = maximumTotalFrames ?? maximumRecords;
  _requireMaximum(maximumRecords, 'maximum chunk records');
  _requireMaximum(maxTotalFrames, 'maximum total frames');
  if (renditions.isEmpty) {
    _manifestInvalid('at least one rendition is required', 'renditions');
  }
  if (renditions.length > maximumRecords) {
    _budget('rendition count cannot fit the chunk record budget');
  }
  if (units.isEmpty) _manifestInvalid('at least one unit is required', 'units');
  if (units.length > maxTotalFrames) {
    _budget('unit count cannot fit the frame budget');
  }

  var totalFrameCount = 0;
  for (var index = 0; index < units.length; index += 1) {
    final unit = units[index];
    if (!_positiveSafe(unit.frameCount)) {
      _manifestInvalid(
          'must be a positive safe integer', 'units[$index].frameCount');
    }
    totalFrameCount =
        checkedAdd(totalFrameCount, unit.frameCount, _uint32Max, 'total unit frames');
    if (totalFrameCount > maxTotalFrames) {
      _budget('total unit frames exceed the active budget');
    }
  }

  final spans = <CanonicalChunkSpan>[];
  final unitSpans =
      List<List<CanonicalChunkSpan>>.generate(units.length, (_) => <CanonicalChunkSpan>[]);
  var ordinal = 0;
  for (var renditionIndex = 0; renditionIndex < renditions.length; renditionIndex += 1) {
    final rendition = renditions[renditionIndex];
    for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
      final unit = units[unitIndex];
      final path = 'units[$unitIndex].chunks[$renditionIndex]';
      if (renditionIndex >= unit.chunks.length) {
        _manifestInvalid('chunk span is missing', path);
      }
      final descriptor = unit.chunks[renditionIndex];
      if (descriptor.rendition != rendition.id) {
        _manifestInvalid(
            'rendition must be ${jsonEncode(rendition.id)}', '$path.rendition');
      }
      if (!_positiveSafe(descriptor.chunkCount)) {
        _manifestInvalid('must be a positive safe integer', '$path.chunkCount');
      }
      if (descriptor.chunkStart != ordinal) {
        _manifestInvalid('must be the canonical ordinal $ordinal', '$path.chunkStart');
      }
      if (descriptor.frameCount != unit.frameCount) {
        _manifestInvalid('must equal the unit frameCount', '$path.frameCount');
      }
      final span = CanonicalChunkSpan(
        renditionIndex: renditionIndex,
        renditionId: rendition.id,
        unitIndex: unitIndex,
        unitId: unit.id,
        chunkStart: ordinal,
        chunkCount: descriptor.chunkCount,
        frameCount: descriptor.frameCount,
      );
      spans.add(span);
      unitSpans[unitIndex].add(span);
      ordinal = checkedAdd(ordinal, descriptor.chunkCount, _uint32Max, 'chunk span end');
      if (ordinal > maximumRecords) {
        _budget('chunk record count exceeds the active budget');
      }
    }
  }

  return CanonicalChunkPlan(
    renditionCount: renditions.length,
    unitCount: units.length,
    totalFrameCount: totalFrameCount,
    recordCount: ordinal,
    spans: spans,
    unitSpans: unitSpans,
  );
}

/// Assert that every unit carries one canonical span per authored rendition.
void validateCanonicalChunkSpans(
  CanonicalChunkPlan plan,
  List<Unit> units, [
  FormatErrorCode code = FormatErrorCode.manifestInvalid,
]) {
  for (final expected in plan.spans) {
    final unitChunks =
        expected.unitIndex < units.length ? units[expected.unitIndex].chunks : null;
    final descriptor = unitChunks != null && expected.renditionIndex < unitChunks.length
        ? unitChunks[expected.renditionIndex]
        : null;
    if (descriptor == null ||
        descriptor.rendition != expected.renditionId ||
        descriptor.chunkStart != expected.chunkStart ||
        descriptor.chunkCount != expected.chunkCount ||
        descriptor.frameCount != expected.frameCount) {
      throw FormatError(
        code,
        'unit ${expected.unitId} chunk span is not canonical',
        FormatErrorDetails(
            path: 'units[${expected.unitIndex}].chunks[${expected.renditionIndex}]'),
      );
    }
  }
  for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
    if (units[unitIndex].chunks.length != plan.renditionCount) {
      throw FormatError(
        code,
        'unit must declare exactly one chunk span per rendition',
        FormatErrorDetails(path: 'units[$unitIndex].chunks'),
      );
    }
  }
}

UnitChunkSpan chunkSpanDescriptor(CanonicalChunkSpan span, String sha256) {
  return UnitChunkSpan(
    rendition: span.renditionId,
    chunkStart: span.chunkStart,
    chunkCount: span.chunkCount,
    frameCount: span.frameCount,
    sha256: sha256,
  );
}

bool _positiveSafe(int value) => value > 0 && value <= maxSafeInteger;

void _requireMaximum(int value, String label) {
  if (value < 0 || value > maxSafeInteger) {
    throw FormatError(
        FormatErrorCode.integerUnsafe, '$label must be a nonnegative safe integer');
  }
}

Never _manifestInvalid(String message, [String? path]) {
  throw FormatError(
    FormatErrorCode.manifestInvalid,
    message,
    path == null ? null : FormatErrorDetails(path: path),
  );
}

Never _budget(String message) {
  throw FormatError(FormatErrorCode.budgetExceeded, message);
}
