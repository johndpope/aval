import type {
  BindingV01,
  MotionPolicy,
  RuntimeFailureCode,
  RuntimeReadiness,
  RuntimeReadinessResult,
  StaticReason
} from "@rendered-motion/player-web";

export const RENDERED_MOTION_TAG_NAME = "rendered-motion" as const;
export const RENDERED_MOTION_ELEMENT_API_MAJOR = 1 as const;

export type RenderedMotionAutoplay = "visible" | "manual";
export type RenderedMotionBindings = "auto" | "none";
export type RenderedMotionCrossOrigin = "anonymous" | "use-credentials";
export type RenderedMotionFit = "contain" | "cover" | "fill" | "none";
export type RenderedMotionMotion = MotionPolicy;
export type RenderedMotionMode = "animated" | "static" | null;

export interface RenderedMotionPrepareOptions {
  readonly signal?: AbortSignal;
  readonly timeoutMs?: number;
}

export interface RenderedMotionPublicFailure {
  readonly code: RuntimeFailureCode | RenderedMotionElementFailureCode;
  readonly message: string;
  readonly operation: string | null;
}

export type RenderedMotionElementFailureCode =
  | "invalid-configuration"
  | "unsupported-browser"
  | "interaction-target-unavailable"
  | "element-cleanup-incomplete";

export interface RenderedMotionReadinessChangeDetail {
  readonly generation: number;
  readonly from: RuntimeReadiness;
  readonly to: RuntimeReadiness;
  readonly reason?: StaticReason;
}

export interface RenderedMotionRequestedStateChangeDetail {
  readonly generation: number;
  readonly from: string;
  readonly to: string;
  readonly sequence: number;
}

export interface RenderedMotionVisualStateChangeDetail {
  readonly generation: number;
  readonly from: string;
  readonly to: string;
}

export interface RenderedMotionTransitionDetail {
  readonly generation: number;
  readonly edge: string;
  readonly from: string;
  readonly to: string;
  readonly sequence?: number;
}

export interface RenderedMotionUnderflowDetail {
  readonly generation: number;
  readonly incident: number;
  readonly heldPresentationOrdinal: string;
  readonly cumulativeCount: number;
}

export interface RenderedMotionFallbackDetail {
  readonly generation: number;
  readonly reason: StaticReason;
  readonly requestedState: string | null;
  readonly visualState: string | null;
}

export interface RenderedMotionErrorDetail {
  readonly generation: number;
  readonly failure: Readonly<RenderedMotionPublicFailure>;
  readonly fatal: boolean;
}

export interface RenderedMotionElementEventMap {
  readonly readinesschange: CustomEvent<Readonly<RenderedMotionReadinessChangeDetail>>;
  readonly requestedstatechange: CustomEvent<Readonly<RenderedMotionRequestedStateChangeDetail>>;
  readonly visualstatechange: CustomEvent<Readonly<RenderedMotionVisualStateChangeDetail>>;
  readonly transitionstart: CustomEvent<Readonly<RenderedMotionTransitionDetail>>;
  readonly transitionend: CustomEvent<Readonly<RenderedMotionTransitionDetail>>;
  readonly underflow: CustomEvent<Readonly<RenderedMotionUnderflowDetail>>;
  readonly fallback: CustomEvent<Readonly<RenderedMotionFallbackDetail>>;
  readonly error: CustomEvent<Readonly<RenderedMotionErrorDetail>>;
}

export interface RenderedMotionTraceRecord {
  readonly index: number;
  readonly kind: string;
  readonly generation: number;
}

export interface RenderedMotionRuntimeMediaCursor {
  readonly path: string;
  readonly unit: string;
  readonly unitInstance: number;
  readonly localFrame: number;
}

export interface RenderedMotionRuntimeTraceRecord {
  readonly index: number;
  readonly kind: "operation" | "content-tick" | "readiness" | "fallback" | "cleanup";
  readonly presentationOrdinal: string | null;
  readonly rationalDeadlineUs: number | null;
  readonly callbackStartMicroseconds: number | null;
  readonly canvasSubmissionCompleteMicroseconds: number | null;
  readonly eligibleAnimationFrameOrdinal: number | null;
  readonly graph: Readonly<{
    readonly operation: string;
    readonly snapshot: Readonly<Record<string, unknown>>;
    readonly presentation: Readonly<Record<string, unknown>> | null;
    readonly effects: readonly Readonly<Record<string, unknown>>[];
  }> | null;
  readonly routeReady: boolean | null;
  readonly selectedBoundary: string | null;
  readonly scheduler: Readonly<{
    readonly generation: number | null;
    readonly activePath: string | null;
    readonly sourceCursor: Readonly<RenderedMotionRuntimeMediaCursor> | null;
    readonly submittedCursor: Readonly<RenderedMotionRuntimeMediaCursor> | null;
    readonly decodedCursor: Readonly<RenderedMotionRuntimeMediaCursor> | null;
    readonly displayedCursor: Readonly<RenderedMotionRuntimeMediaCursor> | null;
    readonly ringSize: number;
    readonly ringCapacity: number;
    readonly smoothSession: boolean;
  }>;
  readonly submitted: readonly Readonly<RenderedMotionRuntimeMediaCursor>[];
  readonly media: Readonly<Record<string, unknown>> | null;
  readonly readbackTag: string | null;
  readonly readiness: RuntimeReadiness;
  readonly decodeLeadFrames: number | null;
  readonly settledRequestIds: readonly number[];
  readonly counters: Readonly<{
    readonly underflows: number;
    readonly fallbacks: number;
    readonly settledRequests: number;
    readonly cleanedFrames: number;
  }>;
}

export interface RenderedMotionDiagnosticsCounters {
  readonly prepare: number;
  readonly sourceReplacement: number;
  readonly pause: number;
  readonly resume: number;
  readonly underflow: number;
  readonly fallback: number;
  readonly contextRecovery: number;
  readonly cleanup: number;
}

/**
 * Immutable terminal ownership proof for the most recently retired source.
 * Participant-scoped fields must reach zero even when other elements still
 * share the page runtime; page-scoped totals are therefore reported
 * separately.
 */
export interface RenderedMotionCleanupReceipt {
  readonly elementGeneration: number;
  readonly sourceGeneration: number;
  readonly completed: boolean;
  readonly failureCount: number;
  readonly playerDisposed: boolean;
  readonly participantDisposed: boolean;
  readonly participantRegistered: boolean;
  readonly participantLogicalBytes: number;
  readonly participantActiveLeaseCount: number;
  readonly participantRegisteredCleanupCount: number;
  readonly participantTrackedWorkCount: number;
  readonly participantPendingWaitCount: number;
  readonly participantDecoderTicketCount: number;
  readonly participantDecoderState: string | null;
  readonly workerCount: number;
  readonly openFrames: number;
  readonly pendingRuntimeOperations: number;
  readonly sourceCopiesInFlight: number;
  readonly rendererStagingBytes: number;
  readonly pendingLoads: number;
  readonly activeTransportBodies: number;
  readonly interestedWaiters: number;
  readonly rendererResourceCount: number;
  readonly contextListenerCount: number;
  readonly stalePublicationCount: number;
  readonly pagePhysicalBytes: number;
  readonly pageParticipantCount: number;
  readonly pageActiveDecoderLeaseCount: number;
  readonly pageQueuedDecoderTicketCount: number;
  readonly pageParkedDecoderTicketCount: number;
}

export interface RenderedMotionElementOwnershipSnapshot {
  readonly listenerCount: number;
  readonly observerCount: number;
  readonly brokerSubscriptionCount: number;
  readonly timerCount: number;
  readonly pendingCommandCount: number;
  readonly failedReleaseCount: number;
  readonly retainedRetryCount: number;
  readonly releaseFailureCount: number;
  readonly completed: boolean;
}

export interface RenderedMotionTerminalCleanupProof {
  readonly completed: boolean;
  readonly sourceCleanupCompleted: boolean;
  readonly elementOwnership: Readonly<RenderedMotionElementOwnershipSnapshot>;
}

export interface RenderedMotionDiagnostics {
  readonly elementGeneration: number;
  readonly sourceGeneration: number;
  readonly inputGeneration: number;
  readonly motionGeneration: number;
  readonly visibilityGeneration: number;
  readonly resizeGeneration: number;
  readonly connected: boolean;
  readonly finalDisposed: boolean;
  readonly readiness: RuntimeReadiness;
  readonly mode: RenderedMotionMode;
  readonly assurance: "best-effort" | null;
  readonly staticReason: StaticReason | null;
  readonly requestedState: string | null;
  readonly visualState: string | null;
  readonly isTransitioning: boolean;
  readonly paused: boolean;
  readonly effectivelyVisible: boolean;
  readonly stateNames: readonly string[];
  readonly eventNames: readonly string[];
  readonly inputBindings: readonly Readonly<BindingV01>[];
  readonly configuredMotion: RenderedMotionMotion;
  readonly hostReducedMotion: boolean | null;
  readonly autoplay: RenderedMotionAutoplay;
  readonly fit: RenderedMotionFit | null;
  readonly lastFailure: Readonly<RenderedMotionPublicFailure> | null;
  readonly counters: Readonly<RenderedMotionDiagnosticsCounters>;
  readonly cleanup: Readonly<RenderedMotionCleanupReceipt> | null;
  readonly elementOwnership: Readonly<RenderedMotionElementOwnershipSnapshot>;
  readonly terminalCleanup: Readonly<RenderedMotionTerminalCleanupProof> | null;
  readonly outstanding: Readonly<Record<string, number>>;
  readonly runtime: Readonly<{
    selectedRendition: string | null;
    selectedProfile: string | null;
    transportMode: "range" | "full" | null;
    declaredFileBytes: number;
    metadataBytes: number;
    verifiedBytes: number;
    residentBlobBytes: number;
    activeTransportBodies: number;
    pendingLoads: number;
    interestedWaiters: number;
    playerTrackedBytes: number;
    pagePhysicalBytes: number;
    activeLeaseCount: number;
    decoderLeaseState: string | null;
    reclamationCount: number;
    contextLossCount: number;
    contextRecoveryCount: number;
  }>;
  readonly motion: Readonly<{
    configured: RenderedMotionMotion;
    hostReducedMotion: boolean | null;
    effective: "reduce" | "full";
    actual: string | null;
  }>;
  readonly playIntent: Readonly<{
    autoplay: RenderedMotionAutoplay;
    manualPlaying: boolean;
    paused: boolean;
  }>;
  readonly visibility: Readonly<{
    documentVisible: boolean;
    intersecting: boolean;
    positiveBox: boolean;
    effectivelyVisible: boolean;
    observerSupported: boolean;
    runtimeVisibility: "visible" | "hidden" | null;
    runtimeSuspension: "active" | "suspending" | "suspended" | null;
    rebuildPending: boolean;
  }>;
  readonly presentation: Readonly<{
    fit: RenderedMotionFit | null;
    cssWidth: number;
    cssHeight: number;
    backingWidth: number;
    backingHeight: number;
    effectiveDprX: number;
    effectiveDprY: number;
    resolutionScale: number;
    clampReasons: readonly string[];
    staticAnimatedMappingEqual: boolean;
  }>;
  readonly elementTrace?: readonly Readonly<RenderedMotionTraceRecord>[];
  readonly runtimeTrace?: readonly Readonly<RenderedMotionRuntimeTraceRecord>[];
}

export interface RenderedMotionElementAttributes {
  readonly src?: string;
  readonly integrity?: string;
  readonly crossorigin?: RenderedMotionCrossOrigin | "";
  readonly motion?: RenderedMotionMotion;
  readonly autoplay?: RenderedMotionAutoplay;
  readonly fit?: RenderedMotionFit;
  readonly bindings?: RenderedMotionBindings;
  readonly state?: string;
  readonly "interaction-for"?: string;
  readonly width?: number | `${number}`;
  readonly height?: number | `${number}`;
}

export interface RenderedMotionElement extends HTMLElement {
  src: string;
  integrity: string;
  crossOrigin: RenderedMotionCrossOrigin;
  motion: RenderedMotionMotion;
  autoplay: RenderedMotionAutoplay;
  fit: RenderedMotionFit | null;
  bindings: RenderedMotionBindings;
  state: string | null;
  interactionFor: string;
  interactionTarget: Element | null;
  width: number | null;
  height: number | null;

  readonly readiness: RuntimeReadiness;
  readonly mode: RenderedMotionMode;
  readonly assurance: "best-effort" | null;
  readonly staticReason: StaticReason | null;
  readonly requestedState: string | null;
  readonly visualState: string | null;
  readonly isTransitioning: boolean;
  readonly paused: boolean;
  readonly effectivelyVisible: boolean;
  readonly stateNames: readonly string[];
  readonly eventNames: readonly string[];
  readonly inputBindings: readonly Readonly<BindingV01>[];

  prepare(options?: Readonly<RenderedMotionPrepareOptions>): Promise<RuntimeReadinessResult>;
  setState(name: string): Promise<void>;
  send(event: string): boolean;
  readyFor(state: string): boolean;
  pause(): void;
  resume(): Promise<void>;
  getDiagnostics(options?: Readonly<{ readonly trace?: boolean }>): Readonly<RenderedMotionDiagnostics>;
  dispose(): Promise<void>;

  addEventListener<K extends keyof RenderedMotionElementEventMap>(
    type: K,
    listener: (this: RenderedMotionElement, event: RenderedMotionElementEventMap[K]) => unknown,
    options?: boolean | AddEventListenerOptions
  ): void;
  addEventListener<K extends keyof HTMLElementEventMap>(
    type: K,
    listener: (this: HTMLElement, event: HTMLElementEventMap[K]) => unknown,
    options?: boolean | AddEventListenerOptions
  ): void;
  addEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ): void;
  removeEventListener<K extends keyof RenderedMotionElementEventMap>(
    type: K,
    listener: (this: RenderedMotionElement, event: RenderedMotionElementEventMap[K]) => unknown,
    options?: boolean | EventListenerOptions
  ): void;
  removeEventListener<K extends keyof HTMLElementEventMap>(
    type: K,
    listener: (this: HTMLElement, event: HTMLElementEventMap[K]) => unknown,
    options?: boolean | EventListenerOptions
  ): void;
  removeEventListener(
    type: string,
    listener: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ): void;
}

export type RenderedMotionElementConstructor = CustomElementConstructor & {
  readonly prototype: RenderedMotionElement;
};

declare global {
  interface HTMLElementTagNameMap {
    "rendered-motion": RenderedMotionElement;
  }
}

export type {
  BindingV01,
  RuntimeReadiness,
  RuntimeReadinessResult,
  StaticReason
};
