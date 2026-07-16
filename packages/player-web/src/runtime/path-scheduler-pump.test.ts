import type {
  DecoderWorkerMetrics,
  DecoderWorkerSample
} from "../decoder-worker/protocol.js";
import type {
  DecoderWorkerWaitOptions,
  ManagedDecoderWorkerFrame
} from "../decoder-worker/client.js";
import { describe, expect, it } from "vitest";

import type {
  PathSchedulerWorkerAdapter
} from "./path-scheduler-model.js";
import { PathSchedulerOutput } from "./path-scheduler-output.js";
import { pumpPathScheduler } from "./path-scheduler-pump.js";
import {
  buildNextPathFrame,
  type PathFramePlan,
  type PathSequenceState
} from "./path-sequence.js";
import type {
  DecoderWorkerSampleBatch,
  WorkerSampleFactory,
  WorkerSampleOutput
} from "./worker-samples.js";

const GENERATION = 1;
const UNIT = "body";
const LIMITS = Object.freeze({
  maxDecodeQueueSize: 12,
  maxPendingSamples: 24,
  maxOutstandingFrames: 12,
  maxDecodedBytes: 12 * 128
});

describe("pumpPathScheduler codec reordering", () => {
  it("finishes a selected-route source group as discard-only dependencies", async () => {
    const worker = new ReorderedWorker(0);
    const output = new PathSchedulerOutput({
      worker,
      rendition: "motion",
      ringCapacity: 6,
      clock: { now: () => 1 },
      onTrace() {}
    });
    output.start(GENERATION, "path");

    const sourceBody = {
      unitId: UNIT,
      kind: "loop" as const,
      frameCount: 8,
      ports: [{ id: "default", entryFrame: 0, portalFrames: [2] }]
    } as const;
    const route = {
      edge: {
        id: "to-target",
        from: "idle",
        to: "target",
        start: {
          type: "portal" as const,
          sourcePort: "default",
          targetPort: "default",
          maxWaitFrames: 6
        },
        transition: {
          kind: "locked" as const,
          unitId: "bridge",
          frameCount: 2
        },
        continuity: "exact-authored" as const
      },
      targetState: "target",
      targetBody: {
        unitId: "target-body",
        kind: "loop" as const,
        frameCount: 2,
        ports: [{ id: "default", entryFrame: 0, portalFrames: [1] }]
      },
      boundary: {
        type: "portal" as const,
        occurrence: 0n,
        frame: 2,
        wraps: false
      }
    } as const;
    const next = [1, 2, 3, 4].map(workerOutput);
    const samples = Object.freeze({
      nextGroupRequirement() {
        return Object.freeze({
          unitId: UNIT,
          firstUnitFrame: 1,
          frameCount: 4,
          chunkCount: 4,
          reorderFrameCount: 2
        });
      },
      createBatch(input: Readonly<{
        frames: readonly Readonly<{ unitId: string; unitFrame: number }>[];
      }>): Readonly<DecoderWorkerSampleBatch> {
        expect(input.frames).toEqual([
          { unitId: UNIT, unitFrame: 1 },
          { unitId: UNIT, unitFrame: 2 },
          { unitId: UNIT, unitFrame: 3 },
          { unitId: UNIT, unitFrame: 4 }
        ]);
        return Object.freeze({
          generation: GENERATION,
          samples: Object.freeze(next.map(decoderSample)),
          outputs: Object.freeze(next),
          release() {}
        });
      }
    }) as unknown as WorkerSampleFactory;
    let committed = pathBuild(1);
    committed.sourceStop = { occurrence: 0n, frame: 2 };

    const report = await pumpPathScheduler({
      options: { targetRingFrames: 2, timeoutMs: 50 },
      ringCapacity: 6,
      limits: LIMITS,
      maxBatchSamples: 12,
      worker,
      samples,
      output,
      build: committed,
      buildFrame: (state, continueCodecGroup) => buildNextPathFrame(state, {
        sourceState: "idle",
        sourceBody,
        route,
        residentTarget: null,
        continueCodecGroup,
        canSubmitSource: () => true
      }),
      commitBuild(state) {
        committed = state;
      },
      recordSubmitted() {},
      onDrain() {}
    });

    expect(report).toMatchObject({
      ringSize: 2,
      submittedFrames: 4,
      decodedFrames: 4,
      discardedFrames: 2
    });
    expect(committed.nextPresentationOrdinal).toBe(3n);
    const firstEdgeFrame = buildNextPathFrame(committed, {
      sourceState: "idle",
      sourceBody,
      route,
      residentTarget: null,
      continueCodecGroup: false,
      canSubmitSource: () => true
    });
    expect(firstEdgeFrame).toMatchObject({
      purpose: "bridge",
      unitId: "bridge",
      unitFrame: 0,
      intendedPresentationOrdinal: 3n
    });
  });

  it("submits a safe group against measured reorder backlog and leaves ring overflow queued", async () => {
    const worker = new ReorderedWorker(5);
    const output = new PathSchedulerOutput({
      worker,
      rendition: "motion",
      ringCapacity: 6,
      clock: { now: () => 1 },
      onTrace() {}
    });
    output.start(GENERATION, "path");

    const prefix = [0, 1, 2].map(workerOutput);
    output.schedule(prefix.map((sample) => framePlan(sample.unitFrame)), prefix);
    worker.enqueue(prefix);
    expect(output.drain().decodedFrames).toBe(3);
    expect(output.ringSize).toBe(3);

    const delayed = [3, 4].map(workerOutput);
    output.schedule(
      delayed.map((sample) => framePlan(sample.unitFrame)),
      delayed
    );
    worker.delay(delayed);

    const next = [5, 6, 7].map(workerOutput);
    const samples = Object.freeze({
      nextGroupRequirement(request: Readonly<{ unitId: string; unitFrame: number }>) {
        expect(request).toEqual({ unitId: UNIT, unitFrame: 5 });
        return Object.freeze({
          unitId: UNIT,
          firstUnitFrame: 5,
          frameCount: 3,
          chunkCount: 3,
          reorderFrameCount: 2
        });
      },
      createBatch(): Readonly<DecoderWorkerSampleBatch> {
        return Object.freeze({
          generation: GENERATION,
          samples: Object.freeze(next.map(decoderSample)),
          outputs: Object.freeze(next),
          release() {}
        });
      }
    }) as unknown as WorkerSampleFactory;
    const build = pathBuild(5);

    const report = await pumpPathScheduler({
      options: { targetRingFrames: 6, timeoutMs: 50 },
      ringCapacity: 6,
      limits: LIMITS,
      maxBatchSamples: 12,
      worker,
      samples,
      output,
      build,
      buildFrame: (state, continueCodecGroup = false) => {
        const cursor = state.sourceNext;
        if (cursor === null || cursor.frame > 7) return null;
        // Models the unresolved source horizon ending at frame 6 while the
        // codec-safe presentation group spans frames 5 through 7.
        if (cursor.frame === 7 && !continueCodecGroup) return null;
        const plan = framePlan(cursor.frame);
        state.sourceNext = cursor.frame === 7
          ? null
          : { occurrence: cursor.occurrence, frame: cursor.frame + 1 };
        state.nextPresentationOrdinal += 1n;
        return plan;
      },
      commitBuild() {},
      recordSubmitted() {},
      onDrain() {}
    });

    expect(report).toMatchObject({
      ringSize: 6,
      expectedOutputs: 2,
      submittedFrames: 3,
      waits: 0
    });
    expect(worker.submitCalls).toBe(1);
    expect(worker.queuedFrames).toBe(2);
    expect(worker.waitCalls).toBe(0);
  });

  it("submits the next group when a reordered unit seam has reserved the final ring slot", async () => {
    const worker = new ReorderedWorker(6);
    const output = new PathSchedulerOutput({
      worker,
      rendition: "motion",
      ringCapacity: 6,
      clock: { now: () => 1 },
      onTrace() {}
    });
    output.start(GENERATION, "path");

    const prefix = [0, 1, 2, 3, 4].map(workerOutput);
    output.schedule(prefix.map((sample) => framePlan(sample.unitFrame)), prefix);
    worker.enqueue(prefix);
    expect(output.drain().decodedFrames).toBe(5);

    const delayed = [5].map(workerOutput);
    output.schedule(delayed.map((sample) => framePlan(sample.unitFrame)), delayed);
    worker.delay(delayed);

    const next = [6, 7, 8, 9].map(workerOutput);
    const samples = Object.freeze({
      nextGroupRequirement() {
        return Object.freeze({
          unitId: UNIT,
          firstUnitFrame: 6,
          frameCount: 4,
          chunkCount: 4,
          reorderFrameCount: 2
        });
      },
      createBatch(): Readonly<DecoderWorkerSampleBatch> {
        return Object.freeze({
          generation: GENERATION,
          samples: Object.freeze(next.map(decoderSample)),
          outputs: Object.freeze(next),
          release() {}
        });
      }
    }) as unknown as WorkerSampleFactory;

    const report = await pumpPathScheduler({
      options: { targetRingFrames: 6, timeoutMs: 50 },
      ringCapacity: 6,
      limits: LIMITS,
      maxBatchSamples: 12,
      worker,
      samples,
      output,
      build: pathBuild(6),
      buildFrame: (state) => {
        const cursor = state.sourceNext;
        if (cursor === null || cursor.frame > 9) return null;
        const plan = framePlan(cursor.frame);
        state.sourceNext = cursor.frame === 9
          ? null
          : { occurrence: cursor.occurrence, frame: cursor.frame + 1 };
        state.nextPresentationOrdinal += 1n;
        return plan;
      },
      commitBuild() {},
      recordSubmitted() {},
      onDrain() {}
    });

    expect(report).toMatchObject({
      ringSize: 6,
      expectedOutputs: 4,
      submittedFrames: 4,
      waits: 0
    });
    expect(worker.submitCalls).toBe(1);
    expect(worker.queuedFrames).toBe(4);
    expect(worker.waitCalls).toBe(0);
  });

  it("returns a partial ring when consuming it is required to fund the next reorder group", async () => {
    const worker = new ReorderedWorker(7);
    const output = new PathSchedulerOutput({
      worker,
      rendition: "motion",
      ringCapacity: 6,
      clock: { now: () => 1 },
      onTrace() {}
    });
    output.start(GENERATION, "path");

    const ready = [0, 1, 2, 3, 4].map(workerOutput);
    output.schedule(ready.map((sample) => framePlan(sample.unitFrame)), ready);
    worker.enqueue(ready);
    expect(output.drain().decodedFrames).toBe(5);
    expect(output.ringSize).toBe(5);

    const retained = [5, 6].map(workerOutput);
    output.schedule(
      retained.map((sample) => framePlan(sample.unitFrame)),
      retained
    );
    worker.delay(retained);

    const next = [7, 8, 9, 10, 11, 12].map(workerOutput);
    const samples = Object.freeze({
      nextGroupRequirement() {
        return Object.freeze({
          unitId: UNIT,
          firstUnitFrame: 7,
          frameCount: 6,
          chunkCount: 6,
          reorderFrameCount: 2
        });
      },
      createBatch(): Readonly<DecoderWorkerSampleBatch> {
        return Object.freeze({
          generation: GENERATION,
          samples: Object.freeze(next.map(decoderSample)),
          outputs: Object.freeze(next),
          release() {}
        });
      }
    }) as unknown as WorkerSampleFactory;

    const build = pathBuild(7);
    const buildFrame = (state: PathSequenceState): Readonly<PathFramePlan> | null => {
      const cursor = state.sourceNext;
      if (cursor === null) return null;
      const plan = framePlan(cursor.frame);
      state.sourceNext = {
        occurrence: cursor.occurrence,
        frame: cursor.frame + 1
      };
      state.nextPresentationOrdinal += 1n;
      return plan;
    };

    const report = await pumpPathScheduler({
      options: { targetRingFrames: 6, timeoutMs: 50 },
      ringCapacity: 6,
      limits: LIMITS,
      maxBatchSamples: 12,
      worker,
      samples,
      output,
      build,
      buildFrame,
      commitBuild() {},
      recordSubmitted() {},
      onDrain() {}
    });

    expect(report).toMatchObject({
      ringSize: 5,
      expectedOutputs: 2,
      submittedFrames: 0,
      waits: 0
    });
    expect(worker.submitCalls).toBe(0);
    expect(worker.waitCalls).toBe(0);

    const consumed = output.takeRingOutput();
    expect(consumed.kind).toBe("frame");
    if (consumed.kind === "frame") consumed.frame.close();
    expect(output.ringSize).toBe(4);

    const resumed = await pumpPathScheduler({
      options: { targetRingFrames: 6, timeoutMs: 50 },
      ringCapacity: 6,
      limits: LIMITS,
      maxBatchSamples: 12,
      worker,
      samples,
      output,
      build,
      buildFrame,
      commitBuild() {},
      recordSubmitted() {},
      onDrain() {}
    });

    expect(resumed).toMatchObject({
      ringSize: 6,
      expectedOutputs: 6,
      submittedFrames: 6,
      waits: 0
    });
    expect(worker.submitCalls).toBe(1);
    expect(worker.queuedFrames).toBe(6);
  });
});

class ReorderedWorker implements PathSchedulerWorkerAdapter {
  public readonly activeGeneration = GENERATION;
  public submitCalls = 0;
  public waitCalls = 0;
  readonly #ready: ReorderedFrame[] = [];
  readonly #open = new Set<ReorderedFrame>();
  #delayed: readonly Readonly<WorkerSampleOutput>[] = [];
  #acceptedSamples: number;
  #submittedFrames = 0;

  public constructor(acceptedSamples: number) {
    this.#acceptedSamples = acceptedSamples;
  }

  public get queuedFrames(): number {
    return this.#ready.length;
  }

  public get openFrames(): number {
    return this.#open.size;
  }

  public enqueue(outputs: readonly Readonly<WorkerSampleOutput>[]): void {
    for (const output of outputs) this.#enqueue(output);
  }

  public delay(outputs: readonly Readonly<WorkerSampleOutput>[]): void {
    this.#delayed = outputs;
    this.#submittedFrames = outputs.length;
  }

  public async activateGeneration(): Promise<void> {}

  public async submit(
    generation: number,
    samples: readonly DecoderWorkerSample[]
  ): Promise<void> {
    expect(generation).toBe(GENERATION);
    this.submitCalls += 1;
    this.#acceptedSamples += samples.length;
    const outputs = samples.map((sample) => workerOutput(
      sample.presentationIndices[0]!
    ));
    this.#submittedFrames += outputs.length;
    this.enqueue([...this.#delayed, ...outputs]);
    this.#delayed = [];
    this.#submittedFrames = 0;
  }

  public async abortGeneration(): Promise<void> {}

  public takeFrame(): ManagedDecoderWorkerFrame | undefined {
    return this.#ready.shift();
  }

  public async waitForFrames(
    _minimum?: number,
    _options?: DecoderWorkerWaitOptions
  ): Promise<void> {
    this.waitCalls += 1;
    throw new Error("scheduler waited instead of submitting the reorder-unblocking group");
  }

  public async snapshotMetrics(): Promise<DecoderWorkerMetrics> {
    return {
      configureCalls: 1,
      resetCalls: 0,
      flushCalls: 0,
      boundaryFlushCalls: 0,
      acceptedSamples: this.#acceptedSamples,
      submittedChunks: this.#acceptedSamples,
      outputFrames: this.#acceptedSamples - this.#submittedFrames,
      deliveredFrames: this.#acceptedSamples - this.#submittedFrames,
      releasedFrames: 0,
      staleFrames: 0,
      closedFrames: 0,
      pendingSamples: 0,
      submittedFrames: this.#submittedFrames,
      leasedFrames: this.#open.size,
      leasedDecodedBytes: this.#open.size * 128,
      decodeQueueSize: 0,
      activeGeneration: GENERATION,
      nextSubmissionOrdinal: this.#acceptedSamples,
      nextOutputOrdinal: this.#acceptedSamples - this.#submittedFrames,
      errors: 0,
      disposed: false
    };
  }

  #enqueue(output: Readonly<WorkerSampleOutput>): void {
    const frame = new ReorderedFrame(output, () => this.#open.delete(frame));
    this.#open.add(frame);
    this.#ready.push(frame);
  }
}

class ReorderedFrame implements ManagedDecoderWorkerFrame {
  public readonly frame = { close() {} } as unknown as VideoFrame;
  public readonly frameId: number;
  public readonly generation = GENERATION;
  public readonly ordinal: number;
  public readonly unitId = UNIT;
  public readonly unitInstance = 0;
  public readonly unitFrame: number;
  public readonly decodeIndex: number;
  public readonly timestamp: number;
  public readonly duration = 1_000;
  public readonly decodedBytes = 128;
  readonly #release: () => void;
  #closed = false;

  public constructor(
    output: Readonly<WorkerSampleOutput>,
    release: () => void
  ) {
    this.frameId = output.ordinal + 1;
    this.ordinal = output.ordinal;
    this.unitFrame = output.unitFrame;
    this.decodeIndex = output.decodeIndex;
    this.timestamp = output.timestamp;
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

function workerOutput(frame: number): Readonly<WorkerSampleOutput> {
  return Object.freeze({
    ordinal: frame,
    unitId: UNIT,
    unitInstance: 0,
    unitFrame: frame,
    decodeIndex: frame,
    timestamp: frame * 1_000,
    duration: 1_000
  });
}

function decoderSample(output: Readonly<WorkerSampleOutput>): DecoderWorkerSample {
  return Object.freeze({
    unitId: UNIT,
    unitInstance: 0,
    decodeIndex: output.decodeIndex,
    unitChunkCount: 8,
    unitFrameCount: 8,
    presentationOrdinalBase: 0,
    presentationIndices: Object.freeze([output.unitFrame]),
    presentationTimestamp: output.timestamp,
    duration: output.duration,
    randomAccess: false,
    displayedFrameCount: 1,
    data: new ArrayBuffer(1)
  });
}

function framePlan(frame: number): Readonly<PathFramePlan> {
  return Object.freeze({
    purpose: "source" as const,
    unitId: UNIT,
    unitFrame: frame,
    state: "idle",
    edge: null,
    graphKind: "body" as const,
    sourceCursor: Object.freeze({ occurrence: 0n, frame }),
    targetCursor: null,
    discard: false,
    intendedPresentationOrdinal: BigInt(frame)
  });
}

function pathBuild(frame: number): PathSequenceState {
  return {
    phase: "source",
    sourceNext: { occurrence: 0n, frame },
    sourceStop: null,
    sourceDiscardBefore: null,
    bridgeNextFrame: 0,
    targetNext: null,
    targetDiscardRemaining: 0,
    nextPresentationOrdinal: BigInt(frame),
    edgeSubmissionStarted: false
  };
}
