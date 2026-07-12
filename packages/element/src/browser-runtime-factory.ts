import {
  BrowserPresentationPlanes,
  BrowserStaticSurfaceDecoder,
  IntegratedPlayer,
  PlayerWebPageRuntime,
  StaticSurfaceStore,
  asStaticSurfaceCatalog,
  createBrowserAvcCandidateComposition,
  type BindingV01,
  type BrowserAvcCandidateComposition,
  type EffectHostEvent,
  type MotionPolicy,
  type PresentationFit,
  type RuntimeAssetSession,
  type RuntimeFailure,
  type RuntimeVisibilityState,
  type StaticReason
} from "@rendered-motion/player-web";

import { ShadowLayerOwner } from "./shadow-layers.js";
import type {
  BrowserRuntimeMetadata,
  BrowserRuntimePlayer
} from "./browser-runtime-contracts.js";
import { BrowserRuntimePlayerOwner } from "./browser-runtime-player.js";
import {
  captureCleanupReceipt,
  settleCleanupOperation
} from "./cleanup-receipt.js";
import type { RenderedMotionCleanupReceipt } from "./public-types.js";
import { RuntimeAcquisitionCleanupError } from "./runtime-acquisition-error.js";

export type {
  BrowserRuntimeMetadata,
  BrowserRuntimePlayer,
  BrowserRuntimePlayerSnapshot
} from "./browser-runtime-contracts.js";

export interface BrowserRuntimeFactoryInput {
  readonly window: Window;
  readonly document: Document;
  readonly layers: ShadowLayerOwner;
  readonly generation: number;
  readonly elementGeneration: number;
  readonly source: string;
  readonly integrity: string;
  readonly credentials: "same-origin" | "include";
  readonly motionPolicy: MotionPolicy;
  readonly hostReducedMotion: boolean;
  readonly initialVisibility: RuntimeVisibilityState;
  readonly signal: AbortSignal;
  readonly eventSink: (event: Readonly<EffectHostEvent>) => void;
  readonly diagnosticsSink: (failure: Readonly<RuntimeFailure>) => void;
  readonly cleanupSink: (receipt: Readonly<RenderedMotionCleanupReceipt>) => void;
  readonly underflowSink: (ordinal: bigint) => void;
  readonly onMetadata: (metadata: Readonly<BrowserRuntimeMetadata>) => void;
}

const PAGE_RUNTIMES = new WeakMap<Window, PlayerWebPageRuntime>();

export async function createBrowserRuntimePlayer(
  input: Readonly<BrowserRuntimeFactoryInput>
): Promise<BrowserRuntimePlayer> {
  const pageRuntime = pageRuntimeFor(input.window);
  const participant = pageRuntime.createParticipant({
    visibility: input.initialVisibility,
    phase: "loading"
  });
  const participantId = participant.snapshot().account.participantId;
  let session: RuntimeAssetSession | null = null;
  let planes: BrowserPresentationPlanes | null = null;
  let composition: Readonly<BrowserAvcCandidateComposition> | null = null;
  let player: IntegratedPlayer | null = null;
  let releaseOwnedPlayer: (() => void) | null = null;
  const staticOwner: {
    store: StaticSurfaceStore | null;
    release: (() => void) | null;
  } = { store: null, release: null };
  const disposeConstruction = async (): Promise<void> => {
    const failures: unknown[] = [];
    const participantDisposal = settleCleanupOperation(
      () => participant.dispose(),
      failures
    );
    await participantDisposal;
    await Promise.all([
      settleCleanupOperation(() => player?.dispose(), failures),
      settleCleanupOperation(() => composition?.controls.settled(), failures)
    ]);
    await settleCleanupOperation(() => session?.dispose(), failures);
    await Promise.all([
      settleCleanupOperation(() => staticOwner.release?.(), failures),
      settleCleanupOperation(() => releaseOwnedPlayer?.(), failures),
      settleCleanupOperation(() => staticOwner.store?.dispose(), failures),
      settleCleanupOperation(() => planes?.dispose(), failures)
    ]);
    const receipt = captureCleanupReceipt({
      elementGeneration: input.elementGeneration,
      sourceGeneration: input.generation,
      participantId,
      pageRuntime,
      participant,
      session,
      planes,
      composition,
      player,
      operationFailureCount: failures.length
    });
    try { input.cleanupSink(receipt); } catch (error) { failures.push(error); }
    if (failures.length > 0 || !receipt.completed) {
      throw failures[0] ?? new Error("runtime construction cleanup is incomplete");
    }
  };
  try {
    const url = new URL(input.source, input.document.baseURI);
    session = await participant.openAsset({
      url,
      credentials: input.credentials,
      signal: input.signal,
      ...(input.integrity === "" ? {} : { integrity: input.integrity })
    });
    const catalog = session.catalog;
    const manifest = catalog.manifest;
    const metadata = captureMetadata(manifest);
    const generation = input.generation;
    planes = await BrowserPresentationPlanes.create({
      animatedCanvas: input.layers.animatedCanvas,
      staticCanvas: input.layers.staticCanvas,
      canvas: manifest.canvas,
      maxBackingBytes: manifest.limits.maxRuntimeBytes,
      backingResources: participant.resources.canvasBacking,
      setStaticVisible: (visible) => {
        if (visible) {
          input.layers.markStaticDrawn(generation);
          input.layers.revealStatic(generation);
        } else {
          input.layers.markAnimatedDrawn(generation);
          input.layers.revealAnimated(generation);
        }
      }
    });
    composition = createBrowserAvcCandidateComposition({
      canvas: input.layers.animatedCanvas,
      presentationPlanes: planes,
      resourceAuthority: participant.resources.candidate,
      diagnosticsSink: input.diagnosticsSink
    });
    const decoder = new BrowserStaticSurfaceDecoder({
      resourceHost: participant.resources.staticDecoder
    });
    const bufferedEvents: Readonly<EffectHostEvent>[] = [];
    let publishEvents = false;
    player = new IntegratedPlayer({
      assetSession: session,
      assetSessionOwnership: "external",
      candidateFactory: composition.factory,
      participantBinding: participant.resources.participant,
      createStaticStore(runtimeCatalog) {
        const created = new StaticSurfaceStore(
          asStaticSurfaceCatalog(runtimeCatalog),
          decoder,
          planes!.staticPlane,
          {
            resourceHost: participant.resources.staticSurfaces,
            retainOptionalSurfaces: true
          }
        );
        staticOwner.store = created;
        return created;
      },
      motionPolicy: input.motionPolicy,
      hostReducedMotion: input.hostReducedMotion,
      initialVisibility: input.initialVisibility,
      realtime: {
        requestFrame: (callback) => input.window.requestAnimationFrame(callback),
        cancelFrame: (handle) => input.window.cancelAnimationFrame(handle),
        now: () => input.window.performance.now(),
        onUnderflow: (event) => input.underflowSink(event.presentationOrdinal)
      },
      eventSink: (event) => {
        if (publishEvents) input.eventSink(event);
        else bufferedEvents.push(event);
      },
      diagnosticsSink: input.diagnosticsSink
    });
    if (staticOwner.store === null) {
      throw new Error("integrated player did not create its strict static store");
    }
    staticOwner.release = participant.registerStaticSurfaceReclaimer(
      staticOwner.store
    );
    releaseOwnedPlayer = participant.ownPlayer(player);
    return new BrowserRuntimePlayerOwner({
      pageRuntime,
      participant,
      session,
      planes,
      composition,
      player,
      metadata,
      releaseOwnedPlayer,
      releaseStaticReclaimer: staticOwner.release,
      staticStore: staticOwner.store,
      elementGeneration: input.elementGeneration,
      sourceGeneration: input.generation,
      cleanupSink: input.cleanupSink,
      diagnosticsSink: input.diagnosticsSink,
      activate: () => {
        input.onMetadata(metadata);
        publishEvents = true;
        for (const event of bufferedEvents) input.eventSink(event);
        bufferedEvents.length = 0;
      }
    });
  } catch (error) {
    try {
      await disposeConstruction();
    } catch (cleanupError) {
      throw new RuntimeAcquisitionCleanupError(
        new AggregateError([error, cleanupError]),
        disposeConstruction
      );
    }
    throw error;
  }
}

function captureMetadata(manifest: Readonly<{
  initialState: string;
  states: readonly Readonly<{ id: string }>[];
  edges: readonly Readonly<{
    trigger?: Readonly<{ type: string; name?: string }>;
  }>[];
  bindings: readonly Readonly<BindingV01>[];
  renditions: readonly Readonly<{ id: string; profile: string }>[];
  canvas: Readonly<{
    width: number;
    height: number;
    fit: PresentationFit;
    pixelAspect: readonly [number, number];
  }>;
}>): Readonly<BrowserRuntimeMetadata> {
  const eventNames: string[] = [];
  const seen = new Set<string>();
  for (const edge of manifest.edges) {
    if (
      edge.trigger?.type === "event" &&
      typeof edge.trigger.name === "string" &&
      !seen.has(edge.trigger.name)
    ) {
      seen.add(edge.trigger.name);
      eventNames.push(edge.trigger.name);
    }
  }
  return Object.freeze({
    initialState: manifest.initialState,
    stateNames: Object.freeze(manifest.states.map(({ id }) => id)),
    eventNames: Object.freeze(eventNames),
    bindings: Object.freeze(manifest.bindings.map((binding) =>
      Object.freeze({ source: binding.source, event: binding.event })
    )),
    renditions: Object.freeze(manifest.renditions.map((rendition) =>
      Object.freeze({ id: rendition.id, profile: rendition.profile })
    )),
    canvas: Object.freeze({
      width: manifest.canvas.width,
      height: manifest.canvas.height,
      fit: manifest.canvas.fit,
      pixelAspect: Object.freeze([
        manifest.canvas.pixelAspect[0],
        manifest.canvas.pixelAspect[1]
      ] as const)
    })
  });
}

function pageRuntimeFor(window: Window): PlayerWebPageRuntime {
  let runtime = PAGE_RUNTIMES.get(window);
  if (runtime === undefined) {
    runtime = new PlayerWebPageRuntime();
    PAGE_RUNTIMES.set(window, runtime);
  }
  return runtime;
}

export type { StaticReason };
