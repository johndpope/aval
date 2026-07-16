// Golden-trace harness: drives the *real* grass-rabbit.avl through the TS
// PathScheduler (with the real WorkerSampleFactory + RuntimeAssetCatalog and a
// deterministic fake decoder worker) and serializes the full trace + takeNext
// media sequence to JSON. The committed JSON
// (flutter/packages/aval_player/test/fixtures/grass_rabbit_golden_trace.json)
// is the golden the Dart `golden_trace_test.dart` diffs against.
//
// Regenerate the fixture with:
//   WRITE_GOLDEN=1 npx vitest run --config vitest.m9.config.ts \
//     packages/player-web/src/runtime/grass-rabbit-golden-trace.test.ts
//
// The scenario (deterministic; identical on the Dart side):
//   1. begin animated in idle: startBody(idle-loop)
//   2. tick 80 frames — wraps the 70-frame idle loop (unitInstance 0 -> 1)
//   3. hover.enter at tick 80: prepareRoute(idle.entering portal edge), commit
//      at the portal boundary, stream into the hover-in target, promote it
//   4. hover.leave: prepareRoute(entering -> exiting via a finish edge), stream
//      to the hover-out target, promote it, then run toward idle again
// The fake worker delivers exactly the frames the scheduler submits, so the
// trace records the scheduler's DECISIONS, not decoded bytes.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

import { describe, expect, it } from "vitest";

import type {
  GraphBodyDefinition,
  GraphEdgeDefinition,
  GraphStartPolicy
} from "@pixel-point/aval-graph";

import { installRuntimeAssetCatalog } from "./asset-catalog.js";
import { DecodeTimeline } from "./decode-timeline.js";
import { WorkerSampleFactory } from "./worker-samples.js";
import { PathScheduler } from "./path-scheduler.js";
import type {
  DecoderWorkerMetrics,
  DecoderWorkerWaitOptions,
  ManagedDecoderWorkerFrame,
  PathSchedulerTakeResult,
  PathSchedulerWorkerAdapter
} from "./path-scheduler-model.js";
import type { DecoderWorkerSample } from "../decoder-worker/protocol.js";

const LIMITS = Object.freeze({
  maxDecodeQueueSize: 8,
  maxPendingSamples: 12,
  maxOutstandingFrames: 12,
  maxDecodedBytes: 12 * 1280 * 720 * 4
});

const RING_CAPACITY = 6;
const IDLE_TICKS = 80;

const ASSET_PATH = fileURLToPath(
  new URL(
    "../../../../examples/grass-rabbit/public/grass-rabbit.avl",
    import.meta.url
  )
);
const FIXTURE_PATH = fileURLToPath(
  new URL(
    "../../../../flutter/packages/aval_player/test/fixtures/grass_rabbit_golden_trace.json",
    import.meta.url
  )
);

describe("grass-rabbit golden trace", () => {
  it("produces a stable scheduler trace and media sequence", async () => {
    const result = await runScenario();
    expect(result.trace.length).toBeGreaterThan(0);
    expect(result.media.length).toBeGreaterThan(0);

    if (process.env.WRITE_GOLDEN === "1") {
      mkdirSync(dirname(FIXTURE_PATH), { recursive: true });
      writeFileSync(FIXTURE_PATH, `${JSON.stringify(result, null, 2)}\n`);
    }
  });
});

interface Scenario {
  readonly meta: {
    readonly rendition: string;
    readonly frameRate: {
      readonly numerator: number;
      readonly denominator: number;
    };
    readonly units: Record<string, number>;
  };
  readonly media: readonly unknown[];
  readonly trace: readonly unknown[];
}

interface StepBox {
  value: number;
}

async function runScenario(): Promise<Scenario> {
  const bytes = new Uint8Array(readFileSync(ASSET_PATH));
  const catalog = installRuntimeAssetCatalog(bytes);
  const manifest = catalog.manifest;
  const rendition = manifest.renditions.find((candidate) =>
    candidate.profile.startsWith("avc-annexb")
  );
  if (rendition === undefined) throw new Error("no AVC rendition");
  const timeline = new DecodeTimeline(manifest.frameRate);
  const worker = new FakeWorker();
  const samples = new WorkerSampleFactory({
    catalog,
    timeline,
    rendition: rendition.id,
    limits: LIMITS
  });
  let now = 0;
  const scheduler = new PathScheduler({
    timeline,
    samples,
    worker,
    rendition: rendition.id,
    ringCapacity: RING_CAPACITY,
    limits: LIMITS,
    clock: { now: () => ++now }
  });

  const unitFrameCounts: Record<string, number> = {};
  for (const unit of manifest.units) unitFrameCounts[unit.id] = unit.frameCount;

  const media: unknown[] = [];
  const step: StepBox = { value: 0 };
  const record = (label: string, result: PathSchedulerTakeResult): void => {
    media.push(serializeTake(step.value, label, result));
    step.value += 1;
    if (result.kind === "frame") result.frame.close();
  };

  // 1-2. Idle loop with wrap.
  await scheduler.startBody({
    state: "idle",
    body: body(manifest, "idle-loop"),
    outgoingStarts: [portalStart("default", "default", 139)],
    path: "idle"
  });
  for (let index = 0; index < IDLE_TICKS; index += 1) {
    await scheduler.pump({ targetRingFrames: RING_CAPACITY });
    record("idle", scheduler.takeNext());
  }

  // 3. hover.enter -> entering (portal edge).
  await routeThrough(
    scheduler,
    portalEdge("idle.entering", "idle", "entering", "default", "default", 139),
    "entering",
    body(manifest, "hover-in"),
    "enter",
    media,
    step
  );

  // 4. hover.leave -> exiting (finish edge from the finite hover-in body).
  await routeThrough(
    scheduler,
    finishEdge("entering.exiting", "entering", "exiting", "default", 66),
    "exiting",
    body(manifest, "hover-out"),
    "leave",
    media,
    step
  );

  for (let index = 0; index < 6; index += 1) {
    await scheduler.pump({ targetRingFrames: RING_CAPACITY });
    record("exiting-tail", scheduler.takeNext());
  }

  const trace = scheduler.trace().map(serializeTraceRecord);
  await scheduler.dispose();

  return {
    meta: {
      rendition: rendition.id,
      frameRate: {
        numerator: manifest.frameRate.numerator,
        denominator: manifest.frameRate.denominator
      },
      units: unitFrameCounts
    },
    media,
    trace
  };
}

async function routeThrough(
  scheduler: PathScheduler,
  edge: GraphEdgeDefinition,
  targetState: string,
  targetBody: GraphBodyDefinition,
  label: string,
  media: unknown[],
  step: StepBox
): Promise<void> {
  await scheduler.prepareRoute({ edge, targetState, targetBody });
  let committed = false;
  for (let guard = 0; guard < 600 && !committed; guard += 1) {
    await scheduler.pump({ targetRingFrames: RING_CAPACITY });
    const decision = scheduler.routeDecision();
    if (decision !== null && decision.kind === "commit-edge") {
      scheduler.commitPreparedRoute();
      committed = true;
      break;
    }
    const result = scheduler.reserveNext(true);
    if (result.kind === "frame") {
      scheduler.commitPreparedPresentation(result.media);
      media.push(serializeTake(step.value, `${label}-source`, result));
      step.value += 1;
      result.frame.close();
    } else {
      media.push(serializeTake(step.value, `${label}-wait`, result));
      step.value += 1;
    }
  }
  if (!committed) throw new Error(`${label} route never committed`);
  for (let index = 0; index < 10; index += 1) {
    await scheduler.pump({ targetRingFrames: RING_CAPACITY });
    media.push(serializeTake(step.value, `${label}-target`, scheduler.takeNext()));
    const last = media[media.length - 1] as { kind: string };
    step.value += 1;
    if (last.kind === "frame") {
      // frame already closed inside serializeTake? No — close here.
    }
  }
  scheduler.promoteTargetToSource({
    state: targetState,
    body: targetBody,
    outgoingStarts: [portalStart("default", "default", 139)]
  });
}

function body(
  manifest: ReturnType<typeof installRuntimeAssetCatalog>["manifest"],
  unitId: string
): GraphBodyDefinition {
  const unit = manifest.units.find((candidate) => candidate.id === unitId);
  if (unit === undefined || unit.kind !== "body") {
    throw new Error(`missing body unit ${unitId}`);
  }
  return {
    unitId: unit.id,
    kind: unit.playback === "loop" ? "loop" : "finite",
    frameCount: unit.frameCount,
    ports: unit.ports.map((port) => ({
      id: port.id,
      entryFrame: 0,
      portalFrames: [...port.portalFrames]
    }))
  };
}

function portalStart(
  sourcePort: string,
  targetPort: string,
  maxWaitFrames: number
): Extract<GraphStartPolicy, { type: "portal" }> {
  return { type: "portal", sourcePort, targetPort, maxWaitFrames };
}

function portalEdge(
  id: string,
  from: string,
  to: string,
  sourcePort: string,
  targetPort: string,
  maxWaitFrames: number
): GraphEdgeDefinition {
  return {
    id,
    from,
    to,
    start: portalStart(sourcePort, targetPort, maxWaitFrames),
    continuity: "exact-authored"
  };
}

function finishEdge(
  id: string,
  from: string,
  to: string,
  targetPort: string,
  maxWaitFrames: number
): GraphEdgeDefinition {
  return {
    id,
    from,
    to,
    start: { type: "finish", targetPort, maxWaitFrames },
    continuity: "exact-authored"
  };
}

function serializeTake(
  step: number,
  label: string,
  result: PathSchedulerTakeResult
): unknown {
  const base: Record<string, unknown> = { step, label, kind: result.kind };
  if (result.kind === "frame") {
    base.purpose = result.purpose;
    Object.assign(base, mediaFields(result.media));
    result.frame.close();
  } else if (result.kind === "resident") {
    Object.assign(base, mediaFields(result.media));
  }
  return base;
}

function mediaFields(media: {
  readonly graphKind: string;
  readonly state: string | null;
  readonly edge: string | null;
  readonly path: string;
  readonly frame: { readonly unit: string; readonly localFrame: number };
  readonly drawSource: string;
  readonly generation: number;
  readonly unitInstance: number;
  readonly decodeOrdinal: number;
  readonly timestamp: number;
  readonly intendedPresentationOrdinal: bigint;
}): Record<string, unknown> {
  return {
    graphKind: media.graphKind,
    state: media.state,
    edge: media.edge,
    path: media.path,
    unit: media.frame.unit,
    localFrame: media.frame.localFrame,
    drawSource: media.drawSource,
    generation: media.generation,
    unitInstance: media.unitInstance,
    decodeOrdinal: media.decodeOrdinal,
    timestamp: media.timestamp,
    intendedPresentationOrdinal: media.intendedPresentationOrdinal.toString()
  };
}

function serializeTraceRecord(record: {
  readonly index: number;
  readonly operation: string;
  readonly generation: number | null;
  readonly path: string | null;
  readonly unit: string | null;
  readonly unitInstance: number | null;
  readonly unitFrame: number | null;
  readonly decodeOrdinal: number | null;
  readonly intendedPresentationOrdinal: bigint | null;
  readonly ringSize: number;
  readonly expectedOutputs: number;
  readonly reason: string | null;
}): unknown {
  return {
    index: record.index,
    operation: record.operation,
    generation: record.generation,
    path: record.path,
    unit: record.unit,
    unitInstance: record.unitInstance,
    unitFrame: record.unitFrame,
    decodeOrdinal: record.decodeOrdinal,
    intendedPresentationOrdinal:
      record.intendedPresentationOrdinal === null
        ? null
        : record.intendedPresentationOrdinal.toString(),
    ringSize: record.ringSize,
    expectedOutputs: record.expectedOutputs,
    reason: record.reason
  };
}

// --- Fake decoder worker (from path-scheduler.test.ts) ---------------------

interface PendingFakeSample {
  readonly generation: number;
  readonly sample: Omit<DecoderWorkerSample, "data">;
}

class FakeWorker implements PathSchedulerWorkerAdapter {
  public activeGeneration: number | null = null;
  public maximumSubmittedBatch = 0;
  public abortCalls = 0;
  readonly #outputsPerWait = 1;
  readonly #pending: PendingFakeSample[] = [];
  readonly #ready: FakeManagedFrame[] = [];
  readonly #open = new Set<FakeManagedFrame>();
  #acceptedSamples = 0;
  #releasedFrames = 0;

  public get queuedFrames(): number {
    return this.#ready.length;
  }

  public get openFrames(): number {
    return this.#open.size;
  }

  public async activateGeneration(generation: number): Promise<void> {
    this.activeGeneration = generation;
    for (const frame of [...this.#ready]) {
      if (frame.generation !== generation) frame.close();
    }
    this.#ready.splice(
      0,
      this.#ready.length,
      ...this.#ready.filter((frame) => !frame.closed)
    );
    this.#pending.length = 0;
  }

  public async submit(
    generation: number,
    samples: readonly DecoderWorkerSample[]
  ): Promise<void> {
    if (generation !== this.activeGeneration) {
      throw new Error("fake generation mismatch");
    }
    this.maximumSubmittedBatch = Math.max(
      this.maximumSubmittedBatch,
      samples.length
    );
    for (const sample of samples) {
      const { data: _data, ...metadata } = sample;
      this.#pending.push({ generation, sample: metadata });
      this.#acceptedSamples += 1;
    }
  }

  public async abortGeneration(generation: number): Promise<void> {
    this.abortCalls += 1;
    this.#pending.splice(
      0,
      this.#pending.length,
      ...this.#pending.filter((item) => item.generation !== generation)
    );
    for (const frame of [...this.#open]) {
      if (frame.generation === generation) frame.close();
    }
    this.#ready.splice(
      0,
      this.#ready.length,
      ...this.#ready.filter((frame) => !frame.closed)
    );
    if (this.activeGeneration === generation) this.activeGeneration = null;
  }

  public takeFrame(): ManagedDecoderWorkerFrame | undefined {
    return this.#ready.shift();
  }

  public async waitForFrames(
    minimum = 1,
    _options: DecoderWorkerWaitOptions = {}
  ): Promise<void> {
    let released = 0;
    while (
      this.#pending.length > 0 &&
      (this.#ready.length < minimum || released < this.#outputsPerWait) &&
      released < this.#outputsPerWait
    ) {
      const pending = this.#pending.shift()!;
      const frame = new FakeManagedFrame(pending, () => {
        this.#open.delete(frame);
        this.#releasedFrames += 1;
      });
      this.#open.add(frame);
      this.#ready.push(frame);
      released += 1;
    }
  }

  public async snapshotMetrics(): Promise<DecoderWorkerMetrics> {
    const activeGeneration = this.activeGeneration;
    const submittedFrames = this.#pending.filter(
      (item) => item.generation === activeGeneration
    ).length;
    const leasedFrames = [...this.#open].filter(
      (frame) => frame.generation === activeGeneration
    ).length;
    return {
      configureCalls: 1,
      resetCalls: 0,
      flushCalls: 0,
      boundaryFlushCalls: 0,
      acceptedSamples: this.#acceptedSamples,
      submittedChunks: this.#acceptedSamples,
      outputFrames: this.#acceptedSamples - this.#pending.length,
      deliveredFrames: this.#acceptedSamples - this.#pending.length,
      releasedFrames: this.#releasedFrames,
      staleFrames: 0,
      closedFrames: this.#releasedFrames,
      pendingSamples: 0,
      submittedFrames,
      leasedFrames,
      leasedDecodedBytes: leasedFrames * 128,
      decodeQueueSize: submittedFrames,
      activeGeneration,
      nextSubmissionOrdinal: this.#acceptedSamples,
      nextOutputOrdinal: this.#acceptedSamples - this.#pending.length,
      errors: 0,
      disposed: false
    };
  }
}

class FakeManagedFrame implements ManagedDecoderWorkerFrame {
  public readonly frame: VideoFrame;
  public readonly frameId: number;
  public readonly generation: number;
  public readonly ordinal: number;
  public readonly unitId: string;
  public readonly unitInstance: number;
  public readonly unitFrame: number;
  public readonly timestamp: number;
  public readonly duration: number;
  public readonly decodedBytes = 128;
  readonly #release: () => void;
  #closed = false;

  public constructor(pending: PendingFakeSample, release: () => void) {
    this.frame = { close() {} } as unknown as VideoFrame;
    this.frameId = pending.sample.ordinal + 1;
    this.generation = pending.generation;
    this.ordinal = pending.sample.ordinal;
    this.unitId = pending.sample.unitId;
    this.unitInstance = pending.sample.unitInstance;
    this.unitFrame = pending.sample.unitFrame;
    this.timestamp = pending.sample.timestamp;
    this.duration = pending.sample.duration;
    this.#release = release;
  }

  public get closed(): boolean {
    return this.#closed;
  }

  public close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.frame.close();
    this.#release();
  }
}
