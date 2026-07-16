import type {
  DecoderWorkerMetrics,
  DecoderWorkerSample
} from "../decoder-worker/protocol.js";
import type {
  DecoderWorkerWaitOptions,
  ManagedDecoderWorkerFrame
} from "../decoder-worker/client.js";
import { describe, expect, it } from "vitest";

import { BrowserNormalRouteOwner } from "./browser-normal-route-owner.js";
import type {
  VideoCandidateActivationInput,
  VideoCandidateReadinessSessionInput
} from "./video-candidate-factory.js";
import type { BorrowedVideoFrame, StreamingFrameHandle } from "./frame-renderer.js";
import type { PathScheduler } from "./path-scheduler.js";
import type {
  CreateWorkerSampleBatchInput,
  DecoderWorkerSampleBatch,
  WorkerSampleGroupRequirement
} from "./worker-samples.js";

const GENERATION = 1;
const UNIT = "intro";
const FRAME_COUNT = 8;
const GROUP_SIZES = [1, 4, 3] as const;

describe("BrowserNormalRouteOwner initial reordered prefix", () => {
  it("progressively submits later safe groups to unblock an H264-like first output", async () => {
    const fixture = createFixture({ releaseFinalSynchronously: true });

    const first = await fixture.owner.prepareInitial(
      introPresentation(0),
      fixture.signal
    );

    expect(first.media.frame.localFrame).toBe(0);
    expect(fixture.samples.submittedGroupSizes).toEqual([1, 4]);
    expect(fixture.worker.waitMinimums).toEqual([]);
    expect(fixture.renderer.uploadedFrames).toEqual([0]);

    const prepared = [first];
    for (let frameIndex = 1; frameIndex < FRAME_COUNT; frameIndex += 1) {
      prepared.push(await fixture.owner.prepareAfterIntro(
        introPresentation(frameIndex - 1),
        fixture.signal
      ));
    }

    expect(prepared.map(({ media }) => media.frame.localFrame)).toEqual(
      [0, 1, 2, 3, 4, 5, 6, 7]
    );
    expect(fixture.samples.submittedGroupSizes).toEqual(GROUP_SIZES);
    expect(fixture.renderer.uploadedFrames).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
    expect(fixture.renderer.slots).toEqual([0, 1, 2, 0, 1, 2, 0, 1]);
    expect(fixture.worker.waitMinimums).toEqual([]);
  });

  it("waits for one output when blocked and uploads only the requested frame", async () => {
    const fixture = createFixture({ releaseFinalSynchronously: false });

    const prepared = [await fixture.owner.prepareInitial(
      introPresentation(0),
      fixture.signal
    )];
    expect(fixture.renderer.uploadedFrames).toEqual([0]);

    for (let frameIndex = 1; frameIndex < FRAME_COUNT; frameIndex += 1) {
      prepared.push(await fixture.owner.prepareAfterIntro(
        introPresentation(frameIndex - 1),
        fixture.signal
      ));
      expect(fixture.renderer.uploadedFrames).toHaveLength(frameIndex + 1);
      expect(fixture.renderer.uploadedFrames.at(-1)).toBe(frameIndex);
    }

    expect(prepared.map(({ media }) => media.frame.localFrame)).toEqual(
      [0, 1, 2, 3, 4, 5, 6, 7]
    );
    expect(fixture.samples.submittedGroupSizes).toEqual(GROUP_SIZES);
    expect(fixture.worker.waitMinimums).toEqual([1, 1, 1, 1, 1]);
  });
});

function createFixture(options: {
  readonly releaseFinalSynchronously: boolean;
}) {
  const worker = new DelayedIntroWorker(options);
  const renderer = new RecordingRenderer();
  const samples = new H264LikeSamples();
  const candidate = {
    context: {
      candidate: { rendition: { id: "h264" } },
      catalog: {
        graph: {
          definition: {
            states: [{
              id: "idle",
              initialUnit: { unitId: UNIT, frameCount: FRAME_COUNT },
              body: { unitId: "body" }
            }],
            edges: []
          }
        }
      }
    },
    worker,
    renderer,
    timeline: { activateNextGeneration: () => GENERATION },
    samples,
    limits: {
      maxDecodeQueueSize: 8,
      maxPendingSamples: 8,
      maxOutstandingFrames: 5,
      maxDecodedBytes: 5 * 128
    }
  } as unknown as VideoCandidateReadinessSessionInput;
  const scheduler = {
    snapshot: () => ({ generation: GENERATION })
  } as unknown as PathScheduler;
  const activation = {
    graphSnapshot: { contentOrdinal: null },
    scheduler,
    finalResourcePlan: { ringCapacity: 3 }
  } as unknown as VideoCandidateActivationInput;
  const controller = new AbortController();
  return {
    owner: new BrowserNormalRouteOwner({ candidate, activation }),
    renderer,
    samples,
    signal: controller.signal,
    worker
  };
}

function introPresentation(frameIndex: number) {
  return Object.freeze({
    kind: "intro" as const,
    state: "idle",
    unitId: UNIT,
    frameIndex
  });
}

class H264LikeSamples {
  public readonly submittedGroupSizes: number[] = [];

  public nextGroupRequirement(request: {
    readonly unitId: string;
    readonly unitFrame: number;
  }): Readonly<WorkerSampleGroupRequirement> {
    const frameCount = request.unitFrame === 0
      ? GROUP_SIZES[0]
      : request.unitFrame === 1
        ? GROUP_SIZES[1]
        : request.unitFrame === 5
          ? GROUP_SIZES[2]
          : null;
    if (request.unitId !== UNIT || frameCount === null) {
      throw new Error("test requested a non-group boundary");
    }
    return Object.freeze({
      unitId: UNIT,
      firstUnitFrame: request.unitFrame,
      frameCount,
      chunkCount: frameCount,
      reorderFrameCount: 2
    });
  }

  public createBatch(
    input: Readonly<CreateWorkerSampleBatchInput>
  ): Readonly<DecoderWorkerSampleBatch> {
    const first = input.frames[0];
    if (first === undefined) throw new Error("test batch is empty");
    this.submittedGroupSizes.push(input.frames.length);
    return Object.freeze({
      generation: GENERATION,
      samples: Object.freeze(input.frames.map(({ unitFrame }) => Object.freeze({
        unitId: UNIT,
        unitInstance: 0,
        decodeIndex: unitFrame,
        unitChunkCount: FRAME_COUNT,
        unitFrameCount: FRAME_COUNT,
        presentationOrdinalBase: 0,
        presentationIndices: Object.freeze([unitFrame]),
        presentationTimestamp: unitFrame * 1_000,
        duration: 1_000,
        randomAccess: unitFrame === 0,
        displayedFrameCount: 1,
        data: new ArrayBuffer(1)
      }))),
      outputs: Object.freeze(input.frames.map(({ unitFrame }) => Object.freeze({
        ordinal: unitFrame,
        unitId: UNIT,
        unitInstance: 0,
        unitFrame,
        decodeIndex: unitFrame,
        timestamp: unitFrame * 1_000,
        duration: 1_000
      }))),
      release() {}
    });
  }
}

class DelayedIntroWorker {
  public activeGeneration: number | null = null;
  public readonly waitMinimums: number[] = [];
  readonly #releaseFinalSynchronously: boolean;
  readonly #delayed: PendingFrame[] = [];
  readonly #ready: TestManagedFrame[] = [];
  readonly #open = new Set<TestManagedFrame>();
  #acceptedSamples = 0;
  #submitCalls = 0;

  public constructor(options: { readonly releaseFinalSynchronously: boolean }) {
    this.#releaseFinalSynchronously = options.releaseFinalSynchronously;
  }

  public get queuedFrames(): number {
    return this.#ready.length;
  }

  public get openFrames(): number {
    return this.#open.size;
  }

  public async activateGeneration(generation: number): Promise<void> {
    this.activeGeneration = generation;
  }

  public async submit(
    generation: number,
    samples: readonly DecoderWorkerSample[]
  ): Promise<void> {
    expect(generation).toBe(GENERATION);
    this.#submitCalls += 1;
    this.#acceptedSamples += samples.length;
    this.#delayed.push(...samples.map((sample) => ({ generation, sample })));
    if (this.#submitCalls === 2) this.#release(3);
    if (this.#submitCalls === 3 && this.#releaseFinalSynchronously) {
      this.#release(this.#delayed.length);
    }
  }

  public async abortGeneration(): Promise<void> {}
  public async configure(): Promise<void> {}
  public async dispose(): Promise<void> {}

  public takeFrame(): ManagedDecoderWorkerFrame | undefined {
    return this.#ready.shift();
  }

  public async waitForFrames(
    minimum = 1,
    _options: DecoderWorkerWaitOptions = {}
  ): Promise<void> {
    this.waitMinimums.push(minimum);
    if (this.#submitCalls < 2) {
      throw new Error("H264 output remains delayed until a later safe group");
    }
    if (this.#ready.length < minimum) this.#release(1);
  }

  public async snapshotMetrics(): Promise<DecoderWorkerMetrics> {
    return {
      configureCalls: 1,
      resetCalls: 0,
      flushCalls: 0,
      boundaryFlushCalls: 0,
      acceptedSamples: this.#acceptedSamples,
      submittedChunks: this.#acceptedSamples,
      outputFrames: this.#acceptedSamples - this.#delayed.length,
      deliveredFrames: this.#acceptedSamples - this.#delayed.length,
      releasedFrames: 0,
      staleFrames: 0,
      closedFrames: 0,
      pendingSamples: 0,
      submittedFrames: this.#delayed.length,
      leasedFrames: this.#open.size,
      leasedDecodedBytes: this.#open.size * 128,
      decodeQueueSize: 0,
      activeGeneration: this.activeGeneration,
      nextSubmissionOrdinal: this.#acceptedSamples,
      nextOutputOrdinal: this.#acceptedSamples - this.#delayed.length,
      errors: 0,
      disposed: false
    };
  }

  #release(count: number): void {
    for (let index = 0; index < count; index += 1) {
      const pending = this.#delayed.shift();
      if (pending === undefined) return;
      const frame = new TestManagedFrame(pending, () => this.#open.delete(frame));
      this.#open.add(frame);
      this.#ready.push(frame);
    }
  }
}

interface PendingFrame {
  readonly generation: number;
  readonly sample: Readonly<DecoderWorkerSample>;
}

class TestManagedFrame implements ManagedDecoderWorkerFrame {
  public readonly frame = { close() {} } as unknown as VideoFrame;
  public readonly frameId: number;
  public readonly generation: number;
  public readonly ordinal: number;
  public readonly unitId: string;
  public readonly unitInstance: number;
  public readonly unitFrame: number;
  public readonly decodeIndex: number;
  public readonly timestamp: number;
  public readonly duration: number;
  public readonly decodedBytes = 128;
  readonly #release: () => void;
  #closed = false;

  public constructor(pending: Readonly<PendingFrame>, release: () => void) {
    const unitFrame = pending.sample.presentationIndices[0];
    if (unitFrame === undefined) throw new Error("test sample is hidden");
    this.frameId = unitFrame + 1;
    this.generation = pending.generation;
    this.ordinal = unitFrame;
    this.unitId = pending.sample.unitId;
    this.unitInstance = pending.sample.unitInstance;
    this.unitFrame = unitFrame;
    this.decodeIndex = pending.sample.decodeIndex;
    this.timestamp = pending.sample.presentationTimestamp;
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

class RecordingRenderer {
  public readonly uploadedFrames: number[] = [];
  public readonly slots: number[] = [];
  #serial = 0;

  public async uploadStreaming(
    slot: number,
    pathGeneration: number,
    source: BorrowedVideoFrame
  ): Promise<StreamingFrameHandle> {
    const frame = source as TestManagedFrame;
    this.uploadedFrames.push(frame.unitFrame);
    this.slots.push(slot);
    source.close();
    this.#serial += 1;
    return Object.freeze({
      kind: "stream",
      slot,
      pathGeneration,
      uploadSerial: this.#serial,
      resourceGeneration: 1
    });
  }
}
