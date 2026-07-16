/// Worker sample factory contract referenced by the path scheduler.
///
/// **Partial port** of `packages/player-web/src/runtime/worker-samples.ts`.
/// The scheduler only holds a [WorkerSampleFactory] and calls [createBatch] on
/// it, so only that public contract (plus the [CreateWorkerSampleBatchInput] /
/// [WorkerSampleFrameRequest] / [DecoderWorkerSampleBatch] shapes it consumes
/// and produces) is ported here as a frozen type.
///
/// Judgment call: the TypeScript `WorkerSampleFactory` is a concrete class
/// whose implementation joins the asset catalog, decode timeline, and sample
/// bytes — all of which depend on modules (`asset-catalog.ts`, aval-format
/// catalog indices, a resource host) outside this task's scope. It is ported
/// here as an `abstract interface class` so the frozen contract the scheduler
/// binds against exists now; the concrete factory (the full `worker-samples.ts`
/// logic) is a later phase's responsibility.
library;

import 'decoder_worker/protocol.dart';

/// One requested source/target frame.
class WorkerSampleFrameRequest {
  const WorkerSampleFrameRequest({
    required this.unitId,
    required this.unitFrame,
  });

  final String unitId;
  final int unitFrame;
}

/// Input to [WorkerSampleFactory.createBatch].
class CreateWorkerSampleBatchInput {
  const CreateWorkerSampleBatchInput({
    required this.frames,
    required this.pendingSamples,
    required this.outstandingFrames,
  });

  final List<WorkerSampleFrameRequest> frames;
  final int pendingSamples;
  final int outstandingFrames;
}

/// A batch of decoder samples with a transfer-claim release hook.
abstract interface class DecoderWorkerSampleBatch {
  int get generation;
  List<DecoderWorkerSample> get samples;

  /// Release the main-thread transfer claim after submit transfers ownership.
  void release();
}

/// Joins catalog records, timeline identity, and sample bytes.
abstract interface class WorkerSampleFactory {
  DecoderWorkerSampleBatch createBatch(CreateWorkerSampleBatchInput input);
}
