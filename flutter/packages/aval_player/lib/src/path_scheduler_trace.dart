/// Bounded scheduler diagnostics log.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-trace.ts`.
/// `PathSchedulerTraceInput` (the TS `Omit<PathSchedulerTraceRecord,"index">`)
/// becomes an explicit immutable class; `Number.MAX_SAFE_INTEGER` maps onto
/// `maxSafeInteger` from `rational_time.dart`.
library;

import 'model.dart' show runtimeTraceCapacity;
import 'path_scheduler_model.dart';
import 'rational_time.dart' show maxSafeInteger;

/// Trace record fields minus the monotonic [PathSchedulerTraceRecord.index].
class PathSchedulerTraceInput {
  const PathSchedulerTraceInput({
    required this.operation,
    required this.generation,
    required this.path,
    required this.unit,
    required this.unitInstance,
    required this.unitFrame,
    required this.decodeOrdinal,
    required this.intendedPresentationOrdinal,
    required this.ringSize,
    required this.expectedOutputs,
    required this.reason,
  });

  final PathSchedulerTraceOperation operation;
  final int? generation;
  final String? path;
  final String? unit;
  final int? unitInstance;
  final int? unitFrame;
  final int? decodeOrdinal;
  final BigInt? intendedPresentationOrdinal;
  final int ringSize;
  final int expectedOutputs;
  final String? reason;
}

/// Bounded, immutable scheduler diagnostics with one monotonic record index.
class PathSchedulerTraceLog {
  final List<PathSchedulerTraceRecord> _records = <PathSchedulerTraceRecord>[];
  int _nextIndex = 0;

  void append(PathSchedulerTraceInput input) {
    if (_nextIndex >= maxSafeInteger) {
      throw RangeError('path scheduler trace index leaves no safe successor');
    }
    _records.add(PathSchedulerTraceRecord(
      index: _nextIndex,
      operation: input.operation,
      generation: input.generation,
      path: input.path,
      unit: input.unit,
      unitInstance: input.unitInstance,
      unitFrame: input.unitFrame,
      decodeOrdinal: input.decodeOrdinal,
      intendedPresentationOrdinal: input.intendedPresentationOrdinal,
      ringSize: input.ringSize,
      expectedOutputs: input.expectedOutputs,
      reason: input.reason,
    ));
    _nextIndex += 1;
    if (_records.length > runtimeTraceCapacity) {
      _records.removeAt(0);
    }
  }

  List<PathSchedulerTraceRecord> snapshot() {
    return List<PathSchedulerTraceRecord>.unmodifiable(_records);
  }
}
