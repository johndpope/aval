import type { GraphPresentation, MotionGraphSnapshot } from "@pixel-point/aval-graph";

import type {
  DecoderWorkerConfigureOptions
} from "../decoder-worker/client.js";
import type { DecoderWorkerLimits } from "../decoder-worker/protocol.js";
import type {
  IntegratedCandidateAttemptContext,
  IntegratedPlaybackSession
} from "./integrated-player-contracts.js";
import type {
  InteractionCachePlan,
  InteractionCacheDeviceLimits
} from "./interaction-cache-plan.js";
import type {
  InteractionCachePreparationInput,
  InteractionCachePreparationReport,
  PrepareInteractionCacheOptions
} from "./interaction-cache-preparation.js";
import type {
  FrameRenderer,
  FrameTextureLayout
} from "./frame-renderer.js";
import type {
  PathScheduler,
  PathSchedulerClock,
  PathSchedulerWorkerAdapter
} from "./path-scheduler.js";
import type {
  ReadinessRunnerAdapters,
  ReadinessRunnerResult
} from "./readiness-runner.js";
import type { RuntimeResourcePlan } from "./resource-plan.js";
import type { RuntimeResourceAllocationSnapshot } from "./resource-plan.js";
import type {
  RuntimeCategoryBytesSnapshot,
  RuntimeDecoderTicket
} from "./model.js";
import type { DecodeTimeline } from "./decode-timeline.js";
import type {
  WorkerSampleFactory,
  WorkerSampleTransferLease
} from "./worker-samples.js";
import type { RuntimeCanvasResourceHost } from "./canvas-resource-plan.js";
import type { BrowserContextRecoveryEventTarget } from "./browser-context-recovery.js";

export type Awaitable<T> = T | PromiseLike<T>;

/** The single candidate-owned decoder surface used by cache and live paths. */
export interface VideoCandidateWorker
  extends PathSchedulerWorkerAdapter {
  configure(options: DecoderWorkerConfigureOptions): Promise<void>;
  dispose(): Promise<void>;
}

export interface VideoCandidateWorkerFactory {
  readonly available: boolean;
  create(
    context: Readonly<IntegratedCandidateAttemptContext>
  ): VideoCandidateWorker;
}

/**
 * A probe exposes limits without allocating textures. The candidate owns both
 * the returned renderer and the probe and disposes each exactly once.
 */
export interface VideoCandidateRendererReservation {
  readonly limits: Readonly<InteractionCacheDeviceLimits>;
  allocate(layout: Readonly<FrameTextureLayout>): FrameRenderer;
  dispose(): Awaitable<void>;
}

export interface VideoCandidateRendererFactory {
  readonly available: boolean;
  create(
    context: Readonly<IntegratedCandidateAttemptContext>
  ): VideoCandidateRendererReservation;
}

export interface VideoCandidateReadinessSessionInput {
  readonly context: Readonly<IntegratedCandidateAttemptContext>;
  readonly worker: VideoCandidateWorker;
  readonly renderer: FrameRenderer;
  readonly interactionCache: Readonly<InteractionCachePlan>;
  readonly provisionalResourcePlan: Readonly<RuntimeResourcePlan>;
  readonly timeline: DecodeTimeline;
  readonly samples: WorkerSampleFactory;
  readonly limits: Readonly<DecoderWorkerLimits>;
  readonly clock: PathSchedulerClock;
  readonly signal: AbortSignal;
  readonly deadlineMs: number;
}

export interface VideoCandidateActivationInput {
  readonly graphSnapshot: Readonly<MotionGraphSnapshot>;
  readonly expectedPresentation: Readonly<GraphPresentation>;
  readonly scheduler: PathScheduler;
  readonly finalResourcePlan: Readonly<RuntimeResourcePlan>;
  readonly signal: AbortSignal;
  readonly deadlineMs: number;
}

/**
 * All fallible first-frame work finishes before this value is returned.
 * `drawInitial` is therefore a synchronous presentation-only operation.
 */
export interface VideoCandidatePreparedMedia {
  readonly playback: IntegratedPlaybackSession;
  drawInitial(): void;
  dispose(): Awaitable<void>;
}

/** Browser/media effects used by the sole all-routes readiness invocation. */
export interface VideoCandidateReadinessSession {
  readonly adapters: Readonly<ReadinessRunnerAdapters>;
  observeResult?(result: Readonly<ReadinessRunnerResult>): void;
  prepareActivation(
    input: Readonly<VideoCandidateActivationInput>
  ): Awaitable<VideoCandidatePreparedMedia>;
  dispose(): Awaitable<void>;
}

export interface VideoCandidateReadinessFactory {
  create(
    input: Readonly<VideoCandidateReadinessSessionInput>
  ): VideoCandidateReadinessSession;
}

export interface VideoCandidateTimerHost {
  setTimeout(callback: () => void, milliseconds: number): unknown;
  clearTimeout(handle: unknown): void;
}

export type VideoCandidateCachePreparer = (
  input: Readonly<InteractionCachePreparationInput>,
  options?: Readonly<PrepareInteractionCacheOptions>
) => Promise<Readonly<InteractionCachePreparationReport>>;

export interface VideoCandidateResourcePlanLeaseSnapshot {
  readonly released: boolean;
  readonly totalBytes: number;
  readonly categories: readonly Readonly<RuntimeCategoryBytesSnapshot>[];
}

export interface VideoCandidateResourcePlanLease {
  snapshot(): Readonly<VideoCandidateResourcePlanLeaseSnapshot>;
  assertAllocation(
    allocation: Readonly<RuntimeResourceAllocationSnapshot>
  ): void;
  claimWorkerTransfer(byteLength: number): WorkerSampleTransferLease;
  release(): void;
}

/** Narrow page authority: byte peak admission plus decoder permission only. */
export interface VideoCandidateResourceAuthority {
  reservePlan(
    allocation: Readonly<RuntimeResourceAllocationSnapshot>
  ): VideoCandidateResourcePlanLease | PromiseLike<VideoCandidateResourcePlanLease>;
  requestDecoder(): RuntimeDecoderTicket;
}

export interface VideoCandidateFactoryOptions {
  readonly workerFactory: VideoCandidateWorkerFactory;
  readonly rendererFactory: VideoCandidateRendererFactory;
  readonly readinessFactory: VideoCandidateReadinessFactory;
  readonly resourceHost?: RuntimeCanvasResourceHost;
  readonly contextTarget?: BrowserContextRecoveryEventTarget;
  readonly resourceAuthority?: VideoCandidateResourceAuthority;
  readonly clock?: PathSchedulerClock;
  readonly timers?: VideoCandidateTimerHost;
  /** Test seam; production defaults to the task-10 preparation owner. */
  readonly prepareCache?: VideoCandidateCachePreparer;
}

export interface VideoCandidateWorkerSetup {
  readonly configure: Readonly<DecoderWorkerConfigureOptions>;
  readonly limits: Readonly<DecoderWorkerLimits>;
}
