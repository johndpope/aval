import type {
  AllRoutesReadinessEvidence,
  AllRoutesReadinessReport
} from "./readiness-evaluator.js";
import type { RuntimeFailure } from "./errors.js";
import type { FrameRendererSnapshot } from "./frame-renderer.js";
import type { PathSchedulerClock, PathSchedulerSnapshot } from "./path-scheduler.js";
import type { DecoderWorkerMetrics } from "../decoder-worker/protocol.js";
import type {
  CreateDecoderWorkerClientOptions,
  OwnedDecoderWorkerPort
} from "../decoder-worker/factory.js";
import type { VideoCandidateTimerHost } from "./video-candidate-factory.js";
import type { CutPresentationSnapshot } from "./cut-presentation-coordinator.js";
import type { ReversiblePresentationSnapshot } from "./reversible-presentation.js";
import type {
  VideoCandidateFactory,
  VideoCandidateResourceAuthority
} from "./video-candidate-factory.js";
import type { BrowserFrameBackendOptions } from "./frame-renderer-browser.js";
import type { BrowserProductionReadinessReport } from "./browser-production-readiness-report.js";
import type { BrowserPresentationPlanes } from "./browser-presentation-planes.js";

export interface BrowserVideoCandidateOrderEntry {
  readonly id: string;
  /** Logical color pixels; packed alpha storage is deliberately excluded. */
  readonly area: number;
  readonly peakBitrate: number;
}

export interface BrowserVideoReadinessSnapshot {
  readonly policy: "all-routes";
  readonly passed: boolean | null;
  readonly evaluation: Readonly<AllRoutesReadinessReport> | null;
  readonly evidence: Readonly<AllRoutesReadinessEvidence> | null;
  readonly production: Readonly<BrowserProductionReadinessReport> | null;
}

export interface BrowserVideoWorkerSnapshot {
  readonly metrics: Readonly<DecoderWorkerMetrics> | null;
  readonly openFrames: number;
  readonly pendingRequests: number;
  readonly pendingWaiters: number;
  readonly alive: boolean;
}

export interface BrowserVideoRendererSnapshot {
  readonly snapshot: Readonly<FrameRendererSnapshot> | null;
  readonly backendAlive: boolean;
  readonly glResourceCount: number;
}

export interface BrowserVideoPlaybackSnapshot {
  readonly scheduler: Readonly<PathSchedulerSnapshot> | null;
  readonly cut: Readonly<CutPresentationSnapshot> | null;
  readonly reversible: Readonly<ReversiblePresentationSnapshot> | null;
  readonly pendingCallbacks: number;
  readonly pendingPromises: number;
  readonly readbackTags: readonly string[];
}

export interface BrowserVideoCandidateCleanupSnapshot {
  readonly workersAlive: number;
  readonly openFrames: number;
  readonly renderersAlive: number;
  readonly glResourceCount: number;
  readonly rendererStagingBytes: number;
  readonly sourceCopiesInFlight: number;
  readonly pendingOperations: number;
  readonly complete: boolean;
}

export interface BrowserVideoCandidateSnapshot {
  readonly candidateOrder: readonly Readonly<BrowserVideoCandidateOrderEntry>[];
  readonly activeRendition: string | null;
  readonly readiness: Readonly<BrowserVideoReadinessSnapshot>;
  readonly worker: Readonly<BrowserVideoWorkerSnapshot>;
  readonly renderer: Readonly<BrowserVideoRendererSnapshot>;
  readonly playback: Readonly<BrowserVideoPlaybackSnapshot>;
  readonly cleanup: Readonly<BrowserVideoCandidateCleanupSnapshot>;
  readonly diagnostics: readonly Readonly<RuntimeFailure>[];
}

export interface BrowserVideoReadPixelsResult {
  readonly rgba: Uint8Array;
  readonly width: number;
  readonly height: number;
}

export interface BrowserVideoCandidateControls {
  settled(): Promise<void>;
  snapshot(): Readonly<BrowserVideoCandidateSnapshot>;
  induceWorkerFailure(): void;
  readPixels(): Readonly<BrowserVideoReadPixelsResult>;
}

/** Test-only constructors; production callers should omit this object. */
export interface BrowserVideoCandidateTestDependencies {
  readonly createWorkerPort?: (
    url: URL,
    options: WorkerOptions
  ) => OwnedDecoderWorkerPort;
  readonly createFrameBackend?: (
    canvas: HTMLCanvasElement
  ) => import("./frame-renderer.js").FrameRendererBackend;
}

export interface BrowserVideoCandidateCompositionOptions {
  readonly canvas: HTMLCanvasElement;
  /** Shared static/animated fit and backing owner for production presentation. */
  readonly presentationPlanes?: Pick<
    BrowserPresentationPlanes,
    | "createFrameBackend"
    | "currentCanvasBacking"
    | "reserveCanvasResources"
    | "ownsAnimatedCanvas"
  > & Partial<Pick<BrowserPresentationPlanes, "animatedContextTarget">>;
  readonly worker?: CreateDecoderWorkerClientOptions;
  readonly renderer?: Readonly<BrowserFrameBackendOptions>;
  readonly clock?: PathSchedulerClock;
  readonly timers?: VideoCandidateTimerHost;
  readonly diagnosticsSink?: (failure: Readonly<RuntimeFailure>) => void;
  /** Optional page-wide byte and decoder admission authority. */
  readonly resourceAuthority?: VideoCandidateResourceAuthority;
  readonly testDependencies?: BrowserVideoCandidateTestDependencies;
}

export interface BrowserVideoCandidateComposition {
  readonly factory: VideoCandidateFactory;
  readonly controls: BrowserVideoCandidateControls;
}
