/// Decoder generation/path tokens and their worker/ring activation order.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-generation.ts`.
/// TS `Promise<void>` → `Future<void>`; `AbortSignal.reason`/`addEventListener`
/// use the extended platform seam in `platform.dart`. The lazy `activateWorker`
/// closure memoizes exactly as the TS version, converting a synchronous throw
/// into a rejected future (`Promise.reject`). `Number.MAX_SAFE_INTEGER` bounds
/// map onto `maxSafeInteger` from `rational_time.dart`.
library;

import 'dart:async';

import 'decode_timeline.dart';
import 'path_scheduler_model.dart'
    show PathSchedulerWorkerActivation, PathSchedulerWorkerAdapter;
import 'path_scheduler_output.dart' show PathSchedulerOutput;
import 'platform.dart';
import 'rational_time.dart' show maxSafeInteger;

/// Construction options for [PathSchedulerGeneration].
class PathSchedulerGenerationOptions {
  const PathSchedulerGenerationOptions({
    required this.timeline,
    required this.worker,
    required this.output,
  });

  final DecodeTimeline timeline;
  final PathSchedulerWorkerAdapter worker;
  final PathSchedulerOutput output;
}

/// A reserved replacement identity: which generation retires, which is next.
class PathSchedulerGenerationPlan {
  const PathSchedulerGenerationPlan({
    required this.retiredGeneration,
    required this.generation,
    required this.path,
  });

  final int retiredGeneration;
  final int generation;
  final String path;
}

/// A committed replacement plus the pending worker acknowledgement.
class PathSchedulerGenerationCommit {
  const PathSchedulerGenerationCommit({
    required this.retiredGeneration,
    required this.generation,
    required this.path,
    required this.activateWorker,
  });

  final int retiredGeneration;
  final int generation;
  final String path;
  final PathSchedulerWorkerActivation activateWorker;
}

/// Owns decoder generation/path tokens and their worker/ring activation order.
class PathSchedulerGeneration {
  PathSchedulerGeneration(PathSchedulerGenerationOptions options)
      : _timeline = options.timeline,
        _worker = options.worker,
        _output = options.output;

  final DecodeTimeline _timeline;
  final PathSchedulerWorkerAdapter _worker;
  final PathSchedulerOutput _output;

  int? _generation;
  String? _path;

  int? get current => _generation;

  String? get path => _path;

  int get nextDecodeOrdinal => _timeline.snapshot().nextOrdinal;

  Future<int> start(String path) async {
    if (_generation != null) {
      throw RangeError('path scheduler generation already started');
    }
    final generation = _timeline.activateNextGeneration();
    _generation = generation;
    _path = path;
    _output.start(generation, path);
    await _worker.activateGeneration(generation);
    return generation;
  }

  /// Reserves identity only; the active generation remains unchanged.
  PathSchedulerGenerationPlan planReplacement(String path) {
    final retiredGeneration = requireGeneration();
    if (retiredGeneration >= maxSafeInteger) {
      throw RangeError('decode generation exceeds the safe-integer range');
    }
    return PathSchedulerGenerationPlan(
      retiredGeneration: retiredGeneration,
      generation: retiredGeneration + 1,
      path: path,
    );
  }

  /// Synchronously installs the exact planned identity, returning only the
  /// worker acknowledgement that an external operation lane must await.
  PathSchedulerGenerationCommit commitReplacement(
    PathSchedulerGenerationPlan plan,
  ) {
    if (_generation != plan.retiredGeneration) {
      throw RangeError('planned path scheduler generation became stale');
    }
    final generation = _timeline.activateNextGeneration();
    if (generation != plan.generation) {
      throw RangeError('decode timeline diverged from its reserved generation');
    }
    _output.activate(generation, plan.path);
    _generation = generation;
    _path = plan.path;
    Future<void>? activation;
    Future<void> activateWorker() {
      if (activation != null) return activation!;
      try {
        activation = _worker.activateGeneration(generation);
      } catch (error) {
        activation = Future<void>.error(error);
      }
      return activation!;
    }

    return PathSchedulerGenerationCommit(
      retiredGeneration: plan.retiredGeneration,
      generation: generation,
      path: plan.path,
      activateWorker: activateWorker,
    );
  }

  Future<void> abortActive() async {
    final generation = _generation;
    if (generation != null && _worker.activeGeneration == generation) {
      await _worker.abortGeneration(generation);
    }
  }

  Future<void> dispose() async {
    await abortActive();
    _generation = null;
    _path = null;
  }

  int requireGeneration() {
    final generation = _generation;
    if (generation == null) {
      throw RangeError('path scheduler has no active generation');
    }
    return generation;
  }

  String requirePath() {
    final path = _path;
    if (path == null) {
      throw RangeError('path scheduler has no active path');
    }
    return path;
  }
}

Future<T> abortablePathSchedulerActivation<T>(
  Future<T> activation, [
  AbortSignal? signal,
]) {
  if (signal == null) return activation;
  if (signal.aborted) {
    // Swallow the superseded activation's outcome; reject with the reason.
    activation.then((_) {}, onError: (_) {});
    return Future<T>.error(signal.reason ?? _defaultAbortReason());
  }
  final completer = Completer<T>();
  late void Function() abort;
  abort = () {
    signal.removeEventListener('abort', abort);
    if (!completer.isCompleted) {
      completer.completeError(signal.reason ?? _defaultAbortReason());
    }
  };
  signal.addEventListener('abort', abort, once: true);
  activation.then(
    (value) {
      signal.removeEventListener('abort', abort);
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error) {
      signal.removeEventListener('abort', abort);
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  return completer.future;
}

Object _defaultAbortReason() =>
    DOMException('the operation was aborted', 'AbortError');

int checkedPathSchedulerSerial(int value) {
  if (value < 0 || value >= maxSafeInteger) {
    throw RangeError('scheduler replacement serial exceeded the safe range');
  }
  return value + 1;
}
