/// Decoder-output expectations, resident frames, and the streaming ring.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-output.ts`.
/// The TS discriminated union `PathSchedulerRingTakeResult` becomes a
/// sealed-class hierarchy; `Object.freeze`d records become immutable classes.
/// The `PathSchedulerOutputTrace` operation string union maps onto the shared
/// [PathSchedulerTraceOperation] enum (only `output`/`discard-output`/
/// `stale-output` are emitted here).
library;

import 'package:aval_graph/aval_graph.dart';

import 'decoder_worker/client_support.dart';
import 'decoder_worker/protocol.dart';
import 'model.dart';
import 'path_scheduler_model.dart';
import 'path_sequence.dart';
import 'presentation_ring.dart';
import 'submission_horizon.dart' show SourceBodyCursor;

/// One planned output joined to its submitted sample and ring identity.
class PathSchedulerExpectedOutput {
  const PathSchedulerExpectedOutput({
    required this.plan,
    required this.sample,
    required this.expected,
  });

  final PathFramePlan plan;
  final DecoderWorkerSample sample;
  final PresentationRingExpectedFrame? expected;
}

/// The result of draining decoder output into the ring.
class PathSchedulerOutputDrainReport {
  const PathSchedulerOutputDrainReport({
    required this.decodedFrames,
    required this.discardedFrames,
    required this.staleFrames,
    required this.decodedCursor,
    required this.decodedSource,
    required this.decodedTarget,
  });

  final int decodedFrames;
  final int discardedFrames;
  final int staleFrames;
  final RuntimeMediaCursor? decodedCursor;
  final SourceBodyCursor? decodedSource;
  final SourceBodyCursor? decodedTarget;
}

/// Callback the output owner uses to trace drained frames.
typedef PathSchedulerOutputTrace = void Function(
  PathSchedulerTraceOperation operation,
  PathSchedulerExpectedOutput? output,
  String? reason,
);

/// Result of [PathSchedulerOutput.takeRingOutput].
sealed class PathSchedulerRingTakeResult {
  const PathSchedulerRingTakeResult();

  String get kind;
}

class PathSchedulerRingTakeUnderflow extends PathSchedulerRingTakeResult {
  const PathSchedulerRingTakeUnderflow();

  @override
  String get kind => 'underflow';
}

class PathSchedulerRingTakeFrame extends PathSchedulerRingTakeResult {
  const PathSchedulerRingTakeFrame({required this.output, required this.frame});

  final PathSchedulerExpectedOutput output;
  final ManagedDecoderWorkerFrame frame;

  @override
  String get kind => 'frame';
}

/// Construction options for [PathSchedulerOutput].
class PathSchedulerOutputOptions {
  const PathSchedulerOutputOptions({
    required this.worker,
    required this.rendition,
    required this.ringCapacity,
    required this.clock,
    required this.onTrace,
  });

  final PathSchedulerWorkerAdapter worker;
  final String rendition;
  final int ringCapacity;
  final PathSchedulerClock clock;
  final PathSchedulerOutputTrace onTrace;
}

/// Owns decoder-output expectations, resident frames, and the streaming ring.
class PathSchedulerOutput {
  PathSchedulerOutput(PathSchedulerOutputOptions options)
      : _worker = options.worker,
        _rendition = options.rendition,
        _ringCapacity = options.ringCapacity,
        _clock = options.clock,
        _onTrace = options.onTrace;

  final PathSchedulerWorkerAdapter _worker;
  final String _rendition;
  final int _ringCapacity;
  final PathSchedulerClock _clock;
  final PathSchedulerOutputTrace _onTrace;
  final List<PathSchedulerExpectedOutput> _expected =
      <PathSchedulerExpectedOutput>[];
  final List<PathSchedulerExpectedOutput> _ringPlans =
      <PathSchedulerExpectedOutput>[];
  final List<RuntimeMediaPresentationFrame> _resident =
      <RuntimeMediaPresentationFrame>[];

  PresentationRing? _ring;
  int? _generation;
  String? _path;
  int _discardedDependencyFrames = 0;
  int _staleFrames = 0;

  int get expectedCount => _expected.length;

  int get residentCount => _resident.length;

  int get discardedDependencyFrames => _discardedDependencyFrames;

  int get staleFrames => _staleFrames;

  int get ringSize => _ring?.snapshot().size ?? 0;

  void start(int generation, String path) {
    if (_ring != null) {
      throw RangeError('path scheduler output already has a ring');
    }
    _generation = generation;
    _path = path;
    _ring = PresentationRing(PresentationRingOptions(
      capacity: _ringCapacity,
      generation: generation,
      path: path,
    ));
  }

  void activate(int generation, String path) {
    final ring = _requireRing();
    _clearQueues();
    ring.activatePath(generation: generation, path: path);
    _generation = generation;
    _path = path;
  }

  void clear() {
    try {
      _ring?.clear();
    } finally {
      _clearQueues();
    }
  }

  void dispose() {
    try {
      _ring?.dispose();
    } finally {
      _clearQueues();
    }
  }

  List<PathSchedulerExpectedOutput> schedule(
    List<PathFramePlan> plans,
    List<DecoderWorkerSample> samples,
  ) {
    if (plans.length != samples.length || plans.isEmpty) {
      throw RangeError('scheduled path output relation is invalid');
    }
    final generation = _requireGeneration();
    final path = _requirePath();
    final outputs = <PathSchedulerExpectedOutput>[];
    for (var index = 0; index < plans.length; index += 1) {
      final plan = plans[index];
      final sample = samples[index];
      final expected = plan.discard
          ? null
          : PresentationRingExpectedFrame(
              generation: generation,
              path: path,
              unitId: sample.unitId,
              unitInstance: sample.unitInstance,
              unitFrame: sample.unitFrame,
              decodeOrdinal: sample.ordinal,
              timestamp: sample.timestamp,
              duration: sample.duration,
              intendedPresentationOrdinal:
                  plan.intendedPresentationOrdinal ?? BigInt.zero,
            );
      outputs.add(PathSchedulerExpectedOutput(
        plan: plan,
        sample: sample,
        expected: expected,
      ));
    }
    _expected.addAll(outputs);
    return outputs;
  }

  int presentableExpectedCount() {
    var count = 0;
    for (final output in _expected) {
      if (!output.plan.discard) count += 1;
    }
    return count;
  }

  bool hasExpected() {
    return _expected.isNotEmpty;
  }

  PathSchedulerExpectedOutput? peekRingOutput() {
    return _ringPlans.isEmpty ? null : _ringPlans[0];
  }

  int availableEdgeLead() {
    final first = _ringPlans.indexWhere(
      (output) => output.plan.purpose != PathSchedulerFramePurpose.source,
    );
    return first < 0 ? 0 : _ringPlans.length - first;
  }

  /// Reclassifies retained decoded target lead as the new stable source ring.
  void promoteTargetToSource(String state, GraphBodyDefinition body) {
    PathSchedulerExpectedOutput promote(PathSchedulerExpectedOutput output) {
      if (output.plan.purpose != PathSchedulerFramePurpose.target) {
        return output;
      }
      final targetCursor = output.plan.targetCursor;
      if (targetCursor == null) {
        throw RangeError('target output has no promotion cursor');
      }
      final cursor = body.kind == GraphBodyKind.loop
          ? targetCursor
          : SourceBodyCursor(occurrence: BigInt.zero, frame: targetCursor.frame);
      return PathSchedulerExpectedOutput(
        plan: PathFramePlan(
          purpose: PathSchedulerFramePurpose.source,
          unitId: output.plan.unitId,
          unitFrame: output.plan.unitFrame,
          state: state,
          edge: null,
          graphKind: output.plan.graphKind,
          sourceCursor: SourceBodyCursor(
            occurrence: cursor.occurrence,
            frame: cursor.frame,
          ),
          targetCursor: null,
          discard: output.plan.discard,
          intendedPresentationOrdinal: output.plan.intendedPresentationOrdinal,
        ),
        sample: output.sample,
        expected: output.expected,
      );
    }

    final promotedExpected = _expected.map(promote).toList();
    _expected
      ..clear()
      ..addAll(promotedExpected);
    final promotedRing = _ringPlans.map(promote).toList();
    _ringPlans
      ..clear()
      ..addAll(promotedRing);
  }

  PathSchedulerRingTakeResult takeRingOutput() {
    final output = _ringPlans.isEmpty ? null : _ringPlans[0];
    if (output == null || output.expected == null) {
      return const PathSchedulerRingTakeUnderflow();
    }
    final result = _requireRing().takeExpected(output.expected!);
    if (result is PresentationRingTakeUnderflow) {
      return const PathSchedulerRingTakeUnderflow();
    }
    _ringPlans.removeAt(0);
    return PathSchedulerRingTakeFrame(
      output: output,
      frame: (result as PresentationRingTakeFrame).entry.frame,
    );
  }

  void replaceResident(List<RuntimeMediaPresentationFrame> media) {
    _resident
      ..clear()
      ..addAll(media);
  }

  RuntimeMediaPresentationFrame? takeResident() {
    return _resident.isEmpty ? null : _resident.removeAt(0);
  }

  PathSchedulerOutputDrainReport drain() {
    var decodedFrames = 0;
    var discardedFrames = 0;
    var staleFrames = 0;
    RuntimeMediaCursor? decodedCursor;
    SourceBodyCursor? decodedSource;
    SourceBodyCursor? decodedTarget;
    while (true) {
      final frame = _worker.takeFrame();
      if (frame == null) break;
      if (frame.generation != _generation) {
        frame.close();
        staleFrames += 1;
        _staleFrames += 1;
        _onTrace(
          PathSchedulerTraceOperation.staleOutput,
          null,
          'obsolete-generation',
        );
        continue;
      }
      final output = _expected.isEmpty ? null : _expected.removeAt(0);
      if (output == null) {
        frame.close();
        throw RangeError('worker produced an unplanned path frame');
      }
      _validateManagedOutput(frame, output.sample);
      decodedFrames += 1;
      decodedCursor = RuntimeMediaCursor(
        path: _requirePath(),
        unit: frame.unitId,
        unitInstance: frame.unitInstance,
        localFrame: frame.unitFrame,
      );
      if (output.plan.sourceCursor != null && !output.plan.discard) {
        final cursor = output.plan.sourceCursor!;
        decodedSource =
            SourceBodyCursor(occurrence: cursor.occurrence, frame: cursor.frame);
      }
      if (output.plan.targetCursor != null && !output.plan.discard) {
        final cursor = output.plan.targetCursor!;
        decodedTarget =
            SourceBodyCursor(occurrence: cursor.occurrence, frame: cursor.frame);
      }
      if (output.plan.discard) {
        frame.close();
        discardedFrames += 1;
        _discardedDependencyFrames += 1;
        _onTrace(PathSchedulerTraceOperation.discardOutput, output, null);
        continue;
      }
      if (output.expected == null) {
        frame.close();
        throw StateError('presentable output has no ring identity');
      }
      final enqueue = _requireRing().enqueue(PresentationRingInsertion(
        expected: output.expected!,
        frame: frame,
        workerOutputTimeMs: _now(),
        uploadReadyTimeMs: null,
      ));
      if (enqueue is PresentationRingEnqueueAccepted) {
        _ringPlans.add(output);
      } else {
        staleFrames += 1;
        _staleFrames += 1;
      }
      _onTrace(PathSchedulerTraceOperation.output, output, null);
    }
    return PathSchedulerOutputDrainReport(
      decodedFrames: decodedFrames,
      discardedFrames: discardedFrames,
      staleFrames: staleFrames,
      decodedCursor: decodedCursor,
      decodedSource: decodedSource,
      decodedTarget: decodedTarget,
    );
  }

  RuntimeMediaPresentationFrame mediaFor(PathSchedulerExpectedOutput output) {
    final expected = output.expected;
    if (expected == null) throw StateError('media output has no identity');
    return RuntimeMediaPresentationFrame(
      graphKind: _graphKindOf(output.plan.graphKind),
      state: output.plan.state,
      edge: output.plan.edge,
      path: expected.path,
      frame: RuntimeFrameKey(
        rendition: _rendition,
        unit: expected.unitId,
        localFrame: expected.unitFrame,
      ),
      drawSource: RuntimeMediaDrawSource.streaming,
      generation: expected.generation,
      unitInstance: expected.unitInstance,
      decodeOrdinal: expected.decodeOrdinal,
      timestamp: expected.timestamp,
      intendedPresentationOrdinal: expected.intendedPresentationOrdinal,
    );
  }

  void _clearQueues() {
    _expected.clear();
    _ringPlans.clear();
    _resident.clear();
  }

  int _now() {
    final value = _clock.now();
    if (value < 0) {
      throw RangeError('scheduler clock must be finite and non-negative');
    }
    return value;
  }

  PresentationRing _requireRing() {
    final ring = _ring;
    if (ring == null) {
      throw RangeError('path scheduler has no presentation ring');
    }
    return ring;
  }

  int _requireGeneration() {
    final generation = _generation;
    if (generation == null) {
      throw RangeError('path scheduler output has no active generation');
    }
    return generation;
  }

  String _requirePath() {
    final path = _path;
    if (path == null) {
      throw RangeError('path scheduler output has no active path');
    }
    return path;
  }
}

/// Maps a [PathFrameGraphKind] onto the media [RuntimeMediaGraphKind]. The TS
/// `graphKind` field is carried through verbatim; the sequence builder only ever
/// emits `body` or `locked`.
RuntimeMediaGraphKind _graphKindOf(PathFrameGraphKind kind) {
  switch (kind) {
    case PathFrameGraphKind.body:
      return RuntimeMediaGraphKind.body;
    case PathFrameGraphKind.locked:
      return RuntimeMediaGraphKind.locked;
  }
}

void _validateManagedOutput(
  ManagedDecoderWorkerFrame frame,
  DecoderWorkerSample sample,
) {
  if (frame.ordinal != sample.ordinal ||
      frame.unitId != sample.unitId ||
      frame.unitInstance != sample.unitInstance ||
      frame.unitFrame != sample.unitFrame ||
      frame.timestamp != sample.timestamp ||
      frame.duration != sample.duration) {
    frame.close();
    throw RangeError('worker output did not match submitted path identity');
  }
}
