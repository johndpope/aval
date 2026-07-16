/// The decoder session's global clock and generation-local unit identity.
///
/// Direct port of `packages/player-web/src/runtime/decode-timeline.ts`.
/// TypeScript `number` counters become Dart `int`; the ordinal-successor bound
/// is computed with `BigInt` exactly where the TS source used `bigint`, to keep
/// the safe-integer overflow checks precise. `Object.freeze` on the returned
/// samples/snapshot becomes `List.unmodifiable` plus immutable value classes.
///
/// Note on `validatePositiveSafeInteger` (decode-timeline.ts:287): unlike the
/// simplified sign-only check used in `rational_time.dart`, this module keeps
/// the upper `Number.MAX_SAFE_INTEGER` guard, because `allocateUnitOccurrence`
/// materializes one frame request per `unitFrameCount` — an unbounded count
/// must be rejected before it is expanded into an array.
library;

import 'rational_time.dart';

const int _maxUnitIdLength = 128;

/// Immutable clock/occurrence fields before record type and bytes are attached.
class DecodeSampleMetadata {
  const DecodeSampleMetadata({
    required this.generation,
    required this.ordinal,
    required this.unitId,
    required this.unitInstance,
    required this.unitFrame,
    required this.unitFrameCount,
    required this.timestamp,
    required this.duration,
  });

  final int generation;
  final int ordinal;
  final String unitId;
  final int unitInstance;
  final int unitFrame;
  final int unitFrameCount;
  final int timestamp;
  final int duration;

  @override
  bool operator ==(Object other) =>
      other is DecodeSampleMetadata &&
      other.generation == generation &&
      other.ordinal == ordinal &&
      other.unitId == unitId &&
      other.unitInstance == unitInstance &&
      other.unitFrame == unitFrame &&
      other.unitFrameCount == unitFrameCount &&
      other.timestamp == timestamp &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(
        generation,
        ordinal,
        unitId,
        unitInstance,
        unitFrame,
        unitFrameCount,
        timestamp,
        duration,
      );

  @override
  String toString() =>
      'DecodeSampleMetadata(generation: $generation, ordinal: $ordinal, '
      'unitId: $unitId, unitInstance: $unitInstance, unitFrame: $unitFrame, '
      'unitFrameCount: $unitFrameCount, timestamp: $timestamp, '
      'duration: $duration)';
}

/// One complete independently-decodable occurrence request.
class DecodeUnitOccurrence {
  const DecodeUnitOccurrence({
    required this.unitId,
    required this.unitFrameCount,
  });

  final String unitId;
  final int unitFrameCount;
}

/// One frame's identity within a planned occurrence batch.
class DecodeTimelineFrameRequest {
  const DecodeTimelineFrameRequest({
    required this.unitId,
    required this.unitFrame,
    required this.unitFrameCount,
  });

  final String unitId;
  final int unitFrame;
  final int unitFrameCount;
}

/// A staged, atomically-committable metadata batch.
///
/// The returned [commit] rejects if another timeline operation ran first.
abstract interface class DecodeTimelineBatchPlan {
  int get generation;
  List<DecodeSampleMetadata> get samples;
  List<DecodeSampleMetadata> commit();
}

/// Immutable snapshot of the timeline's observable counters.
class DecodeTimelineSnapshot {
  const DecodeTimelineSnapshot({
    required this.frameRate,
    required this.activeGeneration,
    required this.nextOrdinal,
    required this.nextUnitInstance,
  });

  final RationalFrameRate frameRate;
  final int? activeGeneration;
  final int nextOrdinal;
  final int nextUnitInstance;

  @override
  bool operator ==(Object other) =>
      other is DecodeTimelineSnapshot &&
      other.frameRate == frameRate &&
      other.activeGeneration == activeGeneration &&
      other.nextOrdinal == nextOrdinal &&
      other.nextUnitInstance == nextUnitInstance;

  @override
  int get hashCode =>
      Object.hash(frameRate, activeGeneration, nextOrdinal, nextUnitInstance);

  @override
  String toString() =>
      'DecodeTimelineSnapshot(frameRate: $frameRate, '
      'activeGeneration: $activeGeneration, nextOrdinal: $nextOrdinal, '
      'nextUnitInstance: $nextUnitInstance)';
}

class _ActiveOccurrence {
  _ActiveOccurrence({
    required this.unitId,
    required this.unitFrameCount,
    required this.unitInstance,
    required this.nextUnitFrame,
  });

  final String unitId;
  final int unitFrameCount;
  final int unitInstance;
  final int nextUnitFrame;
}

/// Owns the decoder session's global clock and generation-local unit identity.
/// It neither owns bytes nor submits work.
class DecodeTimeline {
  DecodeTimeline(RationalFrameRate frameRate)
      : _frameRate = RationalFrameRate(
          numerator: frameRate.numerator,
          denominator: frameRate.denominator,
        ) {
    validateFrameRate(frameRate);
  }

  final RationalFrameRate _frameRate;
  int? _activeGeneration;
  int _nextOrdinal = 0;
  int _nextUnitInstance = 0;
  _ActiveOccurrence? _activeOccurrence;
  int _revision = 0;

  /// Activates the next positive generation without resetting decode time.
  int activateNextGeneration() {
    if (_activeGeneration == maxSafeInteger) {
      throw RangeError('decode generation exceeds the safe-integer range');
    }

    final generation = (_activeGeneration ?? 0) + 1;
    _activeGeneration = generation;
    _nextUnitInstance = 0;
    _activeOccurrence = null;
    _revision += 1;
    return generation;
  }

  /// Atomically assigns one complete independently-decodable occurrence.
  /// Failure leaves every timeline counter unchanged.
  List<DecodeSampleMetadata> allocateUnitOccurrence(
    String unitId,
    int unitFrameCount,
  ) {
    return allocateUnitOccurrences([
      DecodeUnitOccurrence(unitId: unitId, unitFrameCount: unitFrameCount),
    ]);
  }

  /// Assigns one or more complete occurrences in one atomic timeline step.
  List<DecodeSampleMetadata> allocateUnitOccurrences(
    List<DecodeUnitOccurrence> occurrences,
  ) {
    if (_activeGeneration == null) {
      throw RangeError(
        'decode timeline requires an active generation before an occurrence',
      );
    }
    if (occurrences.isEmpty) {
      throw RangeError('decode timeline requires at least one occurrence');
    }

    final frames = <DecodeTimelineFrameRequest>[];
    for (final occurrence in occurrences) {
      _validateUnitId(occurrence.unitId);
      _validatePositiveSafeInteger(
        occurrence.unitFrameCount,
        'unit frame count',
      );
      for (var unitFrame = 0;
          unitFrame < occurrence.unitFrameCount;
          unitFrame += 1) {
        frames.add(DecodeTimelineFrameRequest(
          unitId: occurrence.unitId,
          unitFrame: unitFrame,
          unitFrameCount: occurrence.unitFrameCount,
        ));
      }
    }

    return planSampleBatch(frames).commit();
  }

  /// Builds immutable metadata without mutating counters. The returned commit
  /// is atomic and rejects if another operation changed the timeline first.
  DecodeTimelineBatchPlan planSampleBatch(
    List<DecodeTimelineFrameRequest> frames,
  ) {
    final generation = _activeGeneration;
    if (generation == null) {
      throw RangeError(
        'decode timeline requires an active generation before an occurrence',
      );
    }
    if (frames.isEmpty) {
      throw RangeError('decode timeline batch must contain a frame');
    }
    final finalOrdinal =
        BigInt.from(_nextOrdinal) + BigInt.from(frames.length) - BigInt.one;
    if (finalOrdinal >= BigInt.from(maxSafeInteger)) {
      throw RangeError('decode ordinal leaves no safe successor');
    }

    final revision = _revision;
    var nextUnitInstance = _nextUnitInstance;
    _ActiveOccurrence? activeOccurrence = _activeOccurrence == null
        ? null
        : _ActiveOccurrence(
            unitId: _activeOccurrence!.unitId,
            unitFrameCount: _activeOccurrence!.unitFrameCount,
            unitInstance: _activeOccurrence!.unitInstance,
            nextUnitFrame: _activeOccurrence!.nextUnitFrame,
          );
    var ordinal = _nextOrdinal;
    var timestamp = timestampForFrame(ordinal, _frameRate);
    final samples = <DecodeSampleMetadata>[];

    for (final frame in frames) {
      _validateFrameRequest(frame);
      int unitInstance;
      if (activeOccurrence == null) {
        if (frame.unitFrame != 0) {
          throw RangeError(
            'every decode unit occurrence must begin at frame zero',
          );
        }
        if (nextUnitInstance >= maxSafeInteger) {
          throw RangeError('unit instance leaves no safe successor');
        }
        unitInstance = nextUnitInstance;
        nextUnitInstance += 1;
        activeOccurrence = frame.unitFrameCount == 1
            ? null
            : _ActiveOccurrence(
                unitId: frame.unitId,
                unitFrameCount: frame.unitFrameCount,
                unitInstance: unitInstance,
                nextUnitFrame: 1,
              );
      } else {
        if (frame.unitId != activeOccurrence.unitId ||
            frame.unitFrameCount != activeOccurrence.unitFrameCount ||
            frame.unitFrame != activeOccurrence.nextUnitFrame) {
          throw RangeError(
            'decode unit occurrence frames must remain complete and contiguous',
          );
        }
        unitInstance = activeOccurrence.unitInstance;
        final nextUnitFrame = frame.unitFrame + 1;
        activeOccurrence = nextUnitFrame == frame.unitFrameCount
            ? null
            : _ActiveOccurrence(
                unitId: activeOccurrence.unitId,
                unitFrameCount: activeOccurrence.unitFrameCount,
                unitInstance: activeOccurrence.unitInstance,
                nextUnitFrame: nextUnitFrame,
              );
      }

      final nextTimestamp = timestampForFrame(ordinal + 1, _frameRate);
      final duration = nextTimestamp - timestamp;
      if (duration <= 0 || timestamp > maxSafeInteger - duration) {
        throw RangeError(
          'decode timestamp duration must be positive and remain in the '
          'safe-integer range',
        );
      }
      samples.add(DecodeSampleMetadata(
        generation: generation,
        ordinal: ordinal,
        unitId: frame.unitId,
        unitInstance: unitInstance,
        unitFrame: frame.unitFrame,
        unitFrameCount: frame.unitFrameCount,
        timestamp: timestamp,
        duration: duration,
      ));
      ordinal += 1;
      timestamp = nextTimestamp;
    }

    final immutableSamples = List<DecodeSampleMetadata>.unmodifiable(samples);
    return _DecodeTimelineBatchPlan(
      timeline: this,
      generation: generation,
      samples: immutableSamples,
      revision: revision,
      committedOrdinal: ordinal,
      committedNextUnitInstance: nextUnitInstance,
      committedActiveOccurrence: activeOccurrence,
    );
  }

  DecodeTimelineSnapshot snapshot() {
    return DecodeTimelineSnapshot(
      frameRate: _frameRate,
      activeGeneration: _activeGeneration,
      nextOrdinal: _nextOrdinal,
      nextUnitInstance: _nextUnitInstance,
    );
  }
}

class _DecodeTimelineBatchPlan implements DecodeTimelineBatchPlan {
  _DecodeTimelineBatchPlan({
    required this.timeline,
    required this.generation,
    required this.samples,
    required this.revision,
    required this.committedOrdinal,
    required this.committedNextUnitInstance,
    required this.committedActiveOccurrence,
  });

  final DecodeTimeline timeline;

  @override
  final int generation;

  @override
  final List<DecodeSampleMetadata> samples;

  final int revision;
  final int committedOrdinal;
  final int committedNextUnitInstance;
  final _ActiveOccurrence? committedActiveOccurrence;

  bool _committed = false;

  @override
  List<DecodeSampleMetadata> commit() {
    if (_committed) {
      throw RangeError('decode timeline batch was already committed');
    }
    if (timeline._revision != revision ||
        timeline._activeGeneration != generation) {
      throw RangeError('decode timeline batch plan became stale');
    }
    timeline._nextOrdinal = committedOrdinal;
    timeline._nextUnitInstance = committedNextUnitInstance;
    timeline._activeOccurrence = committedActiveOccurrence;
    timeline._revision += 1;
    _committed = true;
    return samples;
  }
}

void _validateUnitId(String unitId) {
  if (unitId.isEmpty || unitId.length > _maxUnitIdLength) {
    throw RangeError('unit ID length must be between 1 and $_maxUnitIdLength');
  }
}

void _validateFrameRequest(DecodeTimelineFrameRequest frame) {
  _validateUnitId(frame.unitId);
  _validatePositiveSafeInteger(frame.unitFrameCount, 'unit frame count');
  if (frame.unitFrame < 0 || frame.unitFrame >= frame.unitFrameCount) {
    throw RangeError('unit frame must be within the unit frame count');
  }
}

void _validatePositiveSafeInteger(int value, String label) {
  if (value <= 0 || value > maxSafeInteger) {
    throw RangeError('$label must be a positive safe integer');
  }
}
