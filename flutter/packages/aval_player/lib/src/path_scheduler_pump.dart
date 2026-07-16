/// Bounded credit/request pump loop for the path scheduler.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-pump.ts`.
/// TS `Promise` → `Future`; `Math.min`/`Math.max` map onto `dart:math`. The
/// `Number.isFinite` guard on `timeoutMs` is dropped (Dart `int` is always
/// finite); the `>0`/positivity checks are preserved. `batch.release?.()`
/// becomes an unconditional `batch.release()` — the Dart
/// `DecoderWorkerSampleBatch.release` is non-nullable.
library;

import 'dart:math' as math;

import 'decoder_worker/client_support.dart';
import 'decoder_worker/protocol.dart';
import 'path_scheduler_model.dart'
    show
        PathSchedulerPumpOptions,
        PathSchedulerPumpReport,
        PathSchedulerWorkerAdapter;
import 'path_scheduler_output.dart';
import 'path_sequence.dart';
import 'rational_time.dart' show maxSafeInteger;
import 'worker_samples.dart';

const int _defaultPumpTimeoutMs = 2000;
const int _maxPumpIterations = 256;

/// Inputs to [pumpPathScheduler]; the graph routing callbacks stay in
/// `PathScheduler`.
class PumpPathSchedulerInput {
  const PumpPathSchedulerInput({
    required this.options,
    required this.ringCapacity,
    required this.limits,
    required this.maxBatchSamples,
    required this.worker,
    required this.samples,
    required this.output,
    required this.build,
    required this.buildFrame,
    required this.commitBuild,
    required this.recordSubmitted,
    required this.onDrain,
  });

  final PathSchedulerPumpOptions options;
  final int ringCapacity;
  final DecoderWorkerLimits limits;
  final int maxBatchSamples;
  final PathSchedulerWorkerAdapter worker;
  final WorkerSampleFactory samples;
  final PathSchedulerOutput output;
  final PathSequenceState build;
  final PathFramePlan? Function(PathSequenceState state) buildFrame;
  final void Function(PathSequenceState state) commitBuild;
  final void Function(List<PathSchedulerExpectedOutput> outputs) recordSubmitted;
  final void Function(PathSchedulerOutputDrainReport report) onDrain;
}

/// Bounded credit/request loop; graph routing remains in PathScheduler.
Future<PathSchedulerPumpReport> pumpPathScheduler(
  PumpPathSchedulerInput input,
) async {
  final targetRingFrames = input.options.targetRingFrames ?? input.ringCapacity;
  if (targetRingFrames < 1 || targetRingFrames > input.ringCapacity) {
    throw RangeError('pump target must fit the presentation ring');
  }
  final timeoutMs = input.options.timeoutMs ?? _defaultPumpTimeoutMs;
  if (timeoutMs <= 0) {
    throw RangeError('pump timeout must be finite and positive');
  }

  var submittedFrames = 0;
  var decodedFrames = 0;
  var discardedFrames = 0;
  var staleFrames = 0;
  var waits = 0;
  var build = input.build;
  for (var iteration = 0; iteration < _maxPumpIterations; iteration += 1) {
    final drained = input.output.drain();
    input.onDrain(drained);
    decodedFrames += drained.decodedFrames;
    discardedFrames += drained.discardedFrames;
    staleFrames += drained.staleFrames;

    final ringSize = input.output.ringSize;
    if (ringSize >= targetRingFrames) {
      return _report(
        input.output,
        submittedFrames: submittedFrames,
        decodedFrames: decodedFrames,
        discardedFrames: discardedFrames,
        staleFrames: staleFrames,
        waits: waits,
      );
    }

    final metrics = await input.worker.snapshotMetrics();
    final deficit = targetRingFrames -
        ringSize -
        input.output.presentableExpectedCount();
    final pendingCredit =
        math.max(0, input.limits.maxPendingSamples - metrics.pendingSamples);
    final outstanding = _checkedAdd(
      metrics.submittedFrames,
      metrics.leasedFrames,
      'worker outstanding frames',
    );
    final outstandingCredit = math.max(
      0,
      input.limits.maxOutstandingFrames - outstanding,
    );
    final batchLimit = <int>[
      input.maxBatchSamples,
      pendingCredit,
      outstandingCredit,
      math.max(1, deficit),
    ].reduce(math.min);

    if (batchLimit > 0 && deficit > 0) {
      final draft = clonePathSequenceState(build);
      final plans = <PathFramePlan>[];
      for (var index = 0; index < batchLimit; index += 1) {
        final plan = input.buildFrame(draft);
        if (plan == null) break;
        plans.add(plan);
      }
      // A phase-only transition is semantic progress too. Persist terminal
      // finite state even when it emits no decoder request, otherwise reserve
      // reports an underflow forever instead of a held presentation.
      input.commitBuild(draft);
      build = draft;
      if (plans.isNotEmpty) {
        final batch = input.samples.createBatch(CreateWorkerSampleBatchInput(
          frames: plans
              .map((plan) => WorkerSampleFrameRequest(
                    unitId: plan.unitId,
                    unitFrame: plan.unitFrame,
                  ))
              .toList(),
          pendingSamples: metrics.pendingSamples,
          outstandingFrames: outstanding,
        ));
        try {
          final outputs = input.output.schedule(plans, batch.samples);
          input.recordSubmitted(outputs);
          submittedFrames += batch.samples.length;
          await input.worker.submit(batch.generation, batch.samples);
        } finally {
          batch.release();
        }
        continue;
      }
    }

    if (input.output.hasExpected()) {
      final queuedBefore = input.worker.queuedFrames;
      waits += 1;
      await input.worker.waitForFrames(
        1,
        DecoderWorkerWaitOptions(
          signal: input.options.signal,
          timeoutMs: timeoutMs,
        ),
      );
      if (input.worker.queuedFrames <= queuedBefore &&
          input.worker.queuedFrames == 0) {
        throw RangeError('worker frame wait resolved without output');
      }
      continue;
    }

    return _report(
      input.output,
      submittedFrames: submittedFrames,
      decodedFrames: decodedFrames,
      discardedFrames: discardedFrames,
      staleFrames: staleFrames,
      waits: waits,
    );
  }
  throw RangeError('path scheduler pump exceeded its bounded iterations');
}

PathSchedulerPumpReport _report(
  PathSchedulerOutput output, {
  required int submittedFrames,
  required int decodedFrames,
  required int discardedFrames,
  required int staleFrames,
  required int waits,
}) {
  return PathSchedulerPumpReport(
    submittedFrames: submittedFrames,
    decodedFrames: decodedFrames,
    discardedFrames: discardedFrames,
    staleFrames: staleFrames,
    waits: waits,
    ringSize: output.ringSize,
    expectedOutputs: output.expectedCount,
  );
}

int _checkedAdd(int left, int right, String label) {
  if (left < 0 || right < 0 || left > maxSafeInteger - right) {
    throw RangeError('$label exceeded the safe-integer range');
  }
  return left + right;
}
