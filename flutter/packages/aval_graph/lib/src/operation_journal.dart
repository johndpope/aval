/// Operation counters and result trace, ported from
/// `packages/graph/src/operation-journal.ts`.
library;

import 'errors.dart';
import 'limits.dart';
import 'model.dart';

/// Largest sequence number this journal will allocate before throwing,
/// matching JavaScript's `Number.MAX_SAFE_INTEGER` for observable parity
/// with the TypeScript original (see the note in `request_ledger.dart`).
const int _maxSafeInteger = 9007199254740991;

class InputAdmission {
  const InputAdmission({required this.sequence, required this.withinLimit});

  final int sequence;
  final bool withinLimit;
}

class OperationResultMetadata {
  const OperationResultMetadata({
    this.accepted,
    this.joined,
    this.sequence,
    this.requestId,
  });

  final bool? accepted;
  final bool? joined;
  final int? sequence;
  final int? requestId;
}

class CompletedOperation {
  const CompletedOperation({
    required this.operation,
    required this.effects,
    required this.presentation,
    required this.snapshot,
    this.metadata,
  });

  final MotionGraphOperation operation;
  final List<MotionGraphEffect> effects;
  final GraphPresentation? presentation;
  final MotionGraphSnapshot snapshot;
  final OperationResultMetadata? metadata;
}

class OperationJournalCheckpoint {
  const OperationJournalCheckpoint({
    required this.contentOrdinal,
    required this.inputSequence,
    required this.inputsSinceTick,
    required this.routeOperationsLastTick,
    required this.traceIndex,
    required this.trace,
  });

  final BigInt? contentOrdinal;
  final int inputSequence;
  final int inputsSinceTick;
  final int routeOperationsLastTick;
  final int traceIndex;
  final List<MotionGraphTraceRecord> trace;
}

/// Owns the monotonically increasing operation counters and immutable result
/// trace for a graph engine. Tick work remains external: callers admit a
/// tick, perform it, and complete it only after that work succeeds.
class OperationJournal {
  BigInt? _contentOrdinal;
  int _inputSequence = 0;
  int _inputsSinceTick = 0;
  int _routeOperationsLastTick = 0;
  int _traceIndex = 0;
  final List<MotionGraphTraceRecord> _trace = <MotionGraphTraceRecord>[];

  BigInt? get contentOrdinal => _contentOrdinal;

  int get inputSequence => _inputSequence;

  int get inputsSinceTick => _inputsSinceTick;

  int get routeOperationsLastTick => _routeOperationsLastTick;

  /// Pure admission query used by synchronous host-event acceptance checks.
  bool canBeginInput() =>
      _inputsSinceTick < GraphLimits.maxInputsPerTick &&
      _inputSequence < _maxSafeInteger;

  InputAdmission beginInput() {
    final sequence = _nextSequence();
    if (_inputsSinceTick >= GraphLimits.maxInputsPerTick) {
      return InputAdmission(sequence: sequence, withinLimit: false);
    }
    _inputsSinceTick += 1;
    return InputAdmission(sequence: sequence, withinLimit: true);
  }

  int allocateInternalSequence() => _nextSequence();

  void beginTick(BigInt contentOrdinal) {
    final currentOrdinal = _contentOrdinal;
    final expected = currentOrdinal == null ? BigInt.zero : currentOrdinal + BigInt.one;
    if (contentOrdinal != expected) {
      throw MotionGraphError(
        MotionGraphErrorCode.nonConsecutiveTick,
        'content ordinal must be $expected',
      );
    }
    _contentOrdinal = contentOrdinal;
    _routeOperationsLastTick = 0;
  }

  /// Reset the input admission window only after the caller's tick succeeds.
  void completeTick() {
    _inputsSinceTick = 0;
  }

  void incrementRouteOperations() {
    _routeOperationsLastTick += 1;
    if (_routeOperationsLastTick > GraphLimits.maxRoutingOperationsPerTick) {
      throw const MotionGraphError(
        MotionGraphErrorCode.graphValidation,
        'graph exceeded the per-tick routing-operation bound',
      );
    }
  }

  MotionGraphResult record(CompletedOperation completed) {
    final metadata = completed.metadata;
    final result = MotionGraphResult(
      operation: completed.operation,
      accepted: metadata?.accepted,
      joined: metadata?.joined,
      sequence: metadata?.sequence,
      requestId: metadata?.requestId,
      presentation: completed.presentation,
      effects: completed.effects,
      snapshot: completed.snapshot,
    );
    _traceIndex += 1;
    final record = MotionGraphTraceRecord(index: _traceIndex, result: result);
    _trace.add(record);
    if (_trace.length > GraphLimits.maxTraceRecords) {
      _trace.removeRange(0, _trace.length - GraphLimits.maxTraceRecords);
    }
    return result;
  }

  List<MotionGraphTraceRecord> getTrace() => List.unmodifiable(_trace);

  OperationJournalCheckpoint checkpoint() => OperationJournalCheckpoint(
        contentOrdinal: _contentOrdinal,
        inputSequence: _inputSequence,
        inputsSinceTick: _inputsSinceTick,
        routeOperationsLastTick: _routeOperationsLastTick,
        traceIndex: _traceIndex,
        trace: List.unmodifiable(_trace),
      );

  void restore(OperationJournalCheckpoint checkpoint) {
    _contentOrdinal = checkpoint.contentOrdinal;
    _inputSequence = checkpoint.inputSequence;
    _inputsSinceTick = checkpoint.inputsSinceTick;
    _routeOperationsLastTick = checkpoint.routeOperationsLastTick;
    _traceIndex = checkpoint.traceIndex;
    _trace
      ..clear()
      ..addAll(checkpoint.trace);
  }

  int _nextSequence() {
    _inputSequence += 1;
    if (_inputSequence > _maxSafeInteger) {
      throw RangeError('graph input sequence exceeds the safe-integer range');
    }
    return _inputSequence;
  }
}
