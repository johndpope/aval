import {
  DecoderWorkerCoreError,
  expectedTimestamp,
  normalizeCoreError,
  validateConfiguration,
  validateDecodedFrame,
  validateGeneration,
  validateProbeConfiguration,
  validateProbeSupportResult,
  validateSupportResultConfiguration
} from "./core-validation.js";
import { FrameCreditLedger } from "./frame-credit-ledger.js";
import {
  DECODER_WORKER_PROTOCOL_VERSION,
  type DecoderWorkerCommand,
  type DecoderWorkerErrorEvent,
  type DecoderWorkerEvent,
  type DecoderWorkerLimits,
  type DecoderWorkerMetrics,
  type DecoderWorkerOutputExpectation,
  type DecoderWorkerSample
} from "./protocol.js";
import { DecoderSampleSequence } from "./sample-sequence.js";

export interface WorkerVideoDecoderAdapter {
  readonly decodeQueueSize: number;
  setDequeueCallback(callback: () => void): void;
  configure(config: VideoDecoderConfig): void;
  decode(chunk: EncodedVideoChunk): void;
  flush(): Promise<void>;
  close(): void;
}

export type WorkerVideoDecoderFactory = (
  init: VideoDecoderInit
) => WorkerVideoDecoderAdapter;

export type WorkerEncodedVideoChunkFactory = (
  init: EncodedVideoChunkInit
) => EncodedVideoChunk;

export type WorkerVideoDecoderSupportProbe = (
  config: VideoDecoderConfig
) => Promise<VideoDecoderSupport>;

export type DecoderWorkerEventSink = (
  event: DecoderWorkerEvent,
  transfer?: Transferable[]
) => void;

export interface DecoderWorkerCoreOptions {
  readonly emit: DecoderWorkerEventSink;
  readonly decoderFactory?: WorkerVideoDecoderFactory;
  readonly chunkFactory?: WorkerEncodedVideoChunkFactory;
  readonly supportProbe?: WorkerVideoDecoderSupportProbe;
}

interface PendingSample {
  readonly generation: number;
  readonly sample: DecoderWorkerSample;
}

interface SubmittedUnit {
  readonly generation: number;
  readonly unitId: string;
  readonly unitInstance: number;
  readonly unitChunkCount: number;
  readonly unitFrameCount: number;
  readonly presentationOrdinalBase: number;
  readonly buffered: Map<number, BufferedFrame>;
  nextPresentationIndex: number;
  retired: boolean;
}

interface ExpectedFrame {
  readonly unit: SubmittedUnit;
  readonly decodeIndex: number;
  readonly presentationIndex: number;
  readonly timestamp: number;
  readonly duration: number;
}

interface BufferedFrame extends ExpectedFrame {
  readonly outputCallbackMicroseconds: number;
  readonly decodedBytes: number;
  readonly frame: VideoFrame;
}

interface MutableMetrics {
  configureCalls: number;
  flushCalls: number;
  acceptedSamples: number;
  submittedChunks: number;
  outputFrames: number;
  deliveredFrames: number;
  releasedFrames: number;
  staleFrames: number;
  closedFrames: number;
  errors: number;
}

/**
 * Worker-local owner of the sole VideoDecoder.
 *
 * Chunks enter WebCodecs in unit-local decode order. Output callbacks are
 * matched by presentation timestamp and buffered only until the next authored
 * presentation index is available. A unit-ending flush drains delayed frames
 * before the next independent dependency group enters the same decoder.
 */
export class DecoderWorkerCore {
  readonly #emitEvent: DecoderWorkerEventSink;
  readonly #decoderFactory: WorkerVideoDecoderFactory;
  readonly #chunkFactory: WorkerEncodedVideoChunkFactory;
  readonly #supportProbe: WorkerVideoDecoderSupportProbe;
  readonly #pending: PendingSample[] = [];
  readonly #expectedByTimestamp = new Map<number, ExpectedFrame>();
  readonly #deliveryUnits: SubmittedUnit[] = [];
  readonly #credits = new FrameCreditLedger();
  readonly #sequence = new DecoderSampleSequence();
  readonly #metrics: MutableMetrics = {
    configureCalls: 0,
    flushCalls: 0,
    acceptedSamples: 0,
    submittedChunks: 0,
    outputFrames: 0,
    deliveredFrames: 0,
    releasedFrames: 0,
    staleFrames: 0,
    closedFrames: 0,
    errors: 0
  };

  #decoder: WorkerVideoDecoderAdapter | null = null;
  #expectedOutput: DecoderWorkerOutputExpectation | null = null;
  #limits: DecoderWorkerLimits | null = null;
  #activeGeneration: number | null = null;
  #lastGeneration = 0;
  #lastRequestId = 0;
  #nativeUnit: SubmittedUnit | null = null;
  #flushingUnit: SubmittedUnit | null = null;
  #bufferedFrameCount = 0;
  #bufferedDecodedBytes = 0;
  #failure: DecoderWorkerCoreError | null = null;
  #disposed = false;
  #decoderClosed = false;
  #configuring = false;

  public constructor(options: DecoderWorkerCoreOptions) {
    this.#emitEvent = options.emit;
    this.#decoderFactory = options.decoderFactory ?? defaultDecoderFactory;
    this.#chunkFactory = options.chunkFactory ?? defaultChunkFactory;
    this.#supportProbe = options.supportProbe ?? defaultSupportProbe;
  }

  public async handle(command: DecoderWorkerCommand): Promise<void> {
    if (command.type !== "release-frame") {
      if (command.requestId <= this.#lastRequestId) {
        this.#fail(
          new DecoderWorkerCoreError(
            "PROTOCOL_ERROR",
            "decoder worker request ids must increase monotonically",
            true
          ),
          command.requestId
        );
        return;
      }
      this.#lastRequestId = command.requestId;
    }
    if (command.type === "dispose") {
      this.#dispose(command.requestId);
      return;
    }
    if (this.#disposed) {
      this.#emitError(
        command.type === "release-frame" ? null : command.requestId,
        new DecoderWorkerCoreError("DISPOSED", "decoder worker is disposed")
      );
      return;
    }
    if (command.type === "snapshot") {
      this.#emit({
        type: "snapshot",
        protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
        requestId: command.requestId,
        metrics: this.snapshotMetrics()
      });
      return;
    }
    if (this.#failure !== null) {
      this.#emitError(
        command.type === "release-frame" ? null : command.requestId,
        this.#failure
      );
      return;
    }

    try {
      switch (command.type) {
        case "probe-config":
          await this.#probeConfig(command);
          break;
        case "configure":
          await this.#configure(command);
          break;
        case "activate-generation":
          this.#activateGeneration(command.requestId, command.generation);
          break;
        case "submit":
          this.#submit(command.requestId, command.generation, command.samples);
          break;
        case "abort-generation":
          this.#abortGeneration(command.requestId, command.generation);
          break;
        case "release-frame":
          this.#releaseFrame(command.frameId);
          break;
        default:
          command satisfies never;
      }
    } catch (error) {
      const normalized = normalizeCoreError(
        error,
        "PROTOCOL_ERROR",
        "decoder worker command failed",
        false
      );
      if (normalized.fatal) {
        this.#fail(
          normalized,
          command.type === "release-frame" ? null : command.requestId
        );
      } else {
        this.#emitError(
          command.type === "release-frame" ? null : command.requestId,
          normalized
        );
      }
    }
  }

  public rejectMalformedCommand(requestId: number | null): void {
    this.#fail(
      new DecoderWorkerCoreError(
        "PROTOCOL_ERROR",
        "decoder worker received a malformed command",
        true
      ),
      requestId
    );
  }

  public snapshotMetrics(): DecoderWorkerMetrics {
    return Object.freeze({
      configureCalls: this.#metrics.configureCalls,
      resetCalls: 0 as const,
      flushCalls: this.#metrics.flushCalls,
      boundaryFlushCalls: this.#metrics.flushCalls,
      acceptedSamples: this.#metrics.acceptedSamples,
      submittedChunks: this.#metrics.submittedChunks,
      outputFrames: this.#metrics.outputFrames,
      deliveredFrames: this.#metrics.deliveredFrames,
      releasedFrames: this.#metrics.releasedFrames,
      staleFrames: this.#metrics.staleFrames,
      closedFrames: this.#metrics.closedFrames,
      pendingSamples: this.#pending.length,
      submittedFrames:
        this.#pendingDisplayedFrameCount() +
        this.#expectedByTimestamp.size +
        this.#bufferedFrameCount,
      leasedFrames: this.#credits.count,
      leasedDecodedBytes: this.#credits.decodedBytes,
      decodeQueueSize: this.#readDecodeQueueSize(),
      activeGeneration: this.#activeGeneration,
      nextSubmissionOrdinal: this.#sequence.acceptedChunks,
      nextOutputOrdinal:
        this.#metrics.deliveredFrames + this.#metrics.staleFrames,
      errors: this.#metrics.errors,
      disposed: this.#disposed
    });
  }

  async #probeConfig(
    command: Extract<DecoderWorkerCommand, { readonly type: "probe-config" }>
  ): Promise<void> {
    if (
      this.#decoder !== null ||
      this.#metrics.configureCalls !== 0 ||
      this.#configuring
    ) {
      throw new DecoderWorkerCoreError(
        "ALREADY_CONFIGURED",
        "decoder support probes are allowed only before configuration"
      );
    }
    validateProbeConfiguration(command.config);
    let support: VideoDecoderSupport;
    try {
      support = await this.#supportProbe(command.config);
    } catch (error) {
      throw normalizeCoreError(
        error,
        "DECODER_PROBE_FAILED",
        "WebCodecs decoder support probe failed",
        false
      );
    }
    const supported = validateProbeSupportResult(support, command.config);
    this.#emit({
      type: "probe-result",
      protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
      requestId: command.requestId,
      supported
    });
  }

  async #configure(
    command: Extract<DecoderWorkerCommand, { readonly type: "configure" }>
  ): Promise<void> {
    if (
      this.#decoder !== null ||
      this.#metrics.configureCalls !== 0 ||
      this.#configuring
    ) {
      throw new DecoderWorkerCoreError(
        "ALREADY_CONFIGURED",
        "decoder worker may be configured only once"
      );
    }
    validateConfiguration(
      command.config,
      command.videoProfile,
      command.expectedOutput,
      command.limits
    );
    this.#configuring = true;

    let decoder: WorkerVideoDecoderAdapter | null = null;
    try {
      const support = await this.#supportProbe(command.config);
      if (!support.supported || support.config === undefined) {
        throw new DecoderWorkerCoreError(
          "DECODER_CONFIGURE_FAILED",
          "WebCodecs does not support the requested decoder configuration",
          true
        );
      }
      validateSupportResultConfiguration(support.config, command.config);
      decoder = this.#decoderFactory({
        output: (frame) => {
          this.#handleOutput(frame);
        },
        error: (error) => {
          this.#fail(
            normalizeCoreError(
              error,
              "DECODER_OUTPUT_INVALID",
              "WebCodecs decoder failed",
              true
            ),
            null
          );
        }
      });
      decoder.setDequeueCallback(() => {
        this.#pump();
      });
      decoder.configure(command.config);
      if (this.#failure !== null) throw this.#failure;
    } catch (error) {
      const normalized = normalizeCoreError(
        error,
        "DECODER_CONFIGURE_FAILED",
        "failed to configure WebCodecs decoder",
        true
      );
      try {
        decoder?.close();
      } catch {
        // Preserve the original configure failure.
      }
      throw normalized;
    } finally {
      this.#configuring = false;
    }

    if (decoder === null) {
      throw new DecoderWorkerCoreError(
        "DECODER_CONFIGURE_FAILED",
        "decoder factory did not return an adapter",
        true
      );
    }
    this.#decoder = decoder;
    this.#expectedOutput = command.expectedOutput;
    this.#limits = command.limits;
    this.#metrics.configureCalls += 1;
    this.#emitAck(command.requestId, "configure");
  }

  #activateGeneration(requestId: number, generation: number): void {
    this.#assertConfigured();
    validateGeneration(generation);
    if (generation <= this.#lastGeneration) {
      throw new DecoderWorkerCoreError(
        "GENERATION_MISMATCH",
        "decoder generations must increase monotonically"
      );
    }

    this.#retirePendingBefore(generation);
    this.#retirePresentationBefore(generation);
    this.#sequence.activate(generation);
    this.#activeGeneration = generation;
    this.#lastGeneration = generation;
    this.#emitAck(requestId, "activate-generation");
    this.#pump();
  }

  #submit(
    requestId: number,
    generation: number,
    samples: readonly DecoderWorkerSample[]
  ): void {
    this.#assertConfigured();
    if (generation !== this.#activeGeneration) {
      throw new DecoderWorkerCoreError(
        "GENERATION_MISMATCH",
        "decode submission does not target the active generation"
      );
    }
    const limits = this.#requireLimits();
    if (samples.length < 1) {
      throw new DecoderWorkerCoreError(
        "PROTOCOL_ERROR",
        "decode submission must contain at least one sample",
        true
      );
    }
    if (this.#pending.length + samples.length > limits.maxPendingSamples) {
      throw new DecoderWorkerCoreError(
        "BACKPRESSURE_LIMIT",
        "decode submission exceeds the pending-sample budget"
      );
    }
    const newDisplayedFrames = sumDisplayedFrames(samples);
    const outstandingFrames =
      this.#pendingDisplayedFrameCount() +
      this.#expectedByTimestamp.size +
      this.#bufferedFrameCount +
      this.#credits.count;
    if (
      newDisplayedFrames > limits.maxOutstandingFrames - outstandingFrames
    ) {
      throw new DecoderWorkerCoreError(
        "BACKPRESSURE_LIMIT",
        "decode submission exceeds the outstanding-frame budget"
      );
    }

    this.#sequence.accept(generation, samples);
    for (const sample of samples) {
      this.#pending.push({ generation, sample });
    }
    this.#metrics.acceptedSamples += samples.length;
    this.#emitAck(requestId, "submit");
    this.#pump();
  }

  #abortGeneration(requestId: number, generation: number): void {
    this.#assertConfigured();
    validateGeneration(generation);
    if (generation !== this.#activeGeneration) {
      throw new DecoderWorkerCoreError(
        "GENERATION_MISMATCH",
        "only the active decoder generation can be aborted"
      );
    }
    this.#activeGeneration = null;
    this.#retirePendingGeneration(generation);
    this.#retirePresentationGeneration(generation);
    this.#sequence.abort(generation);
    this.#emitAck(requestId, "abort-generation");
    this.#pump();
  }

  #releaseFrame(frameId: number): void {
    this.#credits.release(frameId);
    this.#metrics.releasedFrames += 1;
    this.#drainBufferedFrames();
    this.#pump();
  }

  #pump(): void {
    if (
      this.#failure !== null ||
      this.#disposed ||
      this.#decoder === null ||
      this.#limits === null
    ) {
      return;
    }
    this.#drainBufferedFrames();
    if (this.#flushingUnit !== null) return;

    while (
      this.#pending.length > 0 &&
      this.#readDecodeQueueSize() < this.#limits.maxDecodeQueueSize
    ) {
      const pending = this.#pending[0]!;
      if (pending.generation !== this.#activeGeneration) {
        this.#pending.shift();
        continue;
      }
      if (this.#nativeUnit === null) {
        this.#nativeUnit = createSubmittedUnit(pending);
        this.#deliveryUnits.push(this.#nativeUnit);
      }
      const unit = this.#nativeUnit;
      if (!sameUnit(unit, pending)) {
        this.#startFlush(unit);
        return;
      }
      this.#pending.shift();
      const sample = pending.sample;
      let chunk: EncodedVideoChunk;
      try {
        chunk = this.#chunkFactory({
          type: sample.randomAccess ? "key" : "delta",
          timestamp: sample.presentationTimestamp,
          duration: sample.duration,
          data: sample.data
        });
        this.#registerExpectedFrames(unit, sample);
        this.#decoder.decode(chunk);
      } catch (error) {
        this.#fail(
          normalizeCoreError(
            error,
            "DECODER_SUBMIT_FAILED",
            "WebCodecs rejected an encoded chunk",
            true
          ),
          null
        );
        return;
      }
      this.#metrics.submittedChunks += 1;
      if (sample.decodeIndex === sample.unitChunkCount - 1) {
        this.#startFlush(unit);
        return;
      }
    }
  }

  #registerExpectedFrames(
    unit: SubmittedUnit,
    sample: DecoderWorkerSample
  ): void {
    for (let index = 0; index < sample.presentationIndices.length; index += 1) {
      const presentationIndex = sample.presentationIndices[index]!;
      const timestamp = expectedTimestamp(sample, index);
      if (this.#expectedByTimestamp.has(timestamp)) {
        throw new DecoderWorkerCoreError(
          "DECODER_SUBMIT_FAILED",
          "displayed chunks must have unique in-flight presentation timestamps",
          true
        );
      }
      this.#expectedByTimestamp.set(timestamp, Object.freeze({
        unit,
        decodeIndex: sample.decodeIndex,
        presentationIndex,
        timestamp,
        duration: sample.duration
      }));
    }
  }

  #startFlush(unit: SubmittedUnit): void {
    if (this.#flushingUnit !== null || this.#decoder === null) return;
    this.#flushingUnit = unit;
    this.#metrics.flushCalls += 1;
    let promise: Promise<void>;
    try {
      promise = this.#decoder.flush();
    } catch (error) {
      this.#fail(
        normalizeCoreError(
          error,
          "DECODER_SUBMIT_FAILED",
          "WebCodecs failed to drain an independent unit",
          true
        ),
        null
      );
      return;
    }
    void promise.then(
      () => {
        if (this.#failure !== null || this.#disposed) return;
        if (this.#expectedForUnit(unit) !== 0) {
          this.#fail(
            new DecoderWorkerCoreError(
              "DECODER_OUTPUT_INVALID",
              "decoder flush completed before every displayed frame was output",
              true
            ),
            null
          );
          return;
        }
        if (this.#flushingUnit === unit) this.#flushingUnit = null;
        if (this.#nativeUnit === unit) this.#nativeUnit = null;
        this.#drainBufferedFrames();
        this.#pump();
      },
      (error: unknown) => {
        this.#fail(
          normalizeCoreError(
            error,
            "DECODER_SUBMIT_FAILED",
            "WebCodecs failed to drain an independent unit",
            true
          ),
          null
        );
      }
    );
  }

  #handleOutput(frame: VideoFrame): void {
    const outputCallbackMicroseconds = workerClockMicroseconds();
    this.#metrics.outputFrames += 1;
    if (this.#disposed || this.#failure !== null) {
      this.#closeFrame(frame);
      return;
    }

    const expected = this.#expectedByTimestamp.get(frame.timestamp);
    if (expected === undefined) {
      this.#closeFrame(frame);
      this.#fail(
        new DecoderWorkerCoreError(
          "DECODER_OUTPUT_INVALID",
          "decoder produced an output with an unknown presentation timestamp",
          true
        ),
        null
      );
      return;
    }
    this.#expectedByTimestamp.delete(frame.timestamp);
    let ownsFrame = true;
    try {
      const decodedBytes = validateDecodedFrame(
        frame,
        this.#requireExpectedOutput(),
        expected.timestamp,
        expected.duration
      );
      if (
        expected.unit.retired ||
        expected.unit.generation !== this.#activeGeneration
      ) {
        this.#metrics.staleFrames += 1;
        this.#closeFrame(frame);
        ownsFrame = false;
        this.#pump();
        return;
      }
      const limits = this.#requireLimits();
      if (
        decodedBytes >
          limits.maxDecodedBytes -
            this.#bufferedDecodedBytes -
            this.#credits.decodedBytes
      ) {
        throw new DecoderWorkerCoreError(
          "DECODED_BYTE_BUDGET_EXCEEDED",
          "decoded output exceeds the worker frame-byte budget",
          true
        );
      }
      if (expected.unit.buffered.has(expected.presentationIndex)) {
        throw new DecoderWorkerCoreError(
          "DECODER_OUTPUT_INVALID",
          "decoder produced a duplicate unit presentation frame",
          true
        );
      }
      expected.unit.buffered.set(expected.presentationIndex, {
        ...expected,
        outputCallbackMicroseconds,
        decodedBytes,
        frame
      });
      this.#bufferedFrameCount += 1;
      this.#bufferedDecodedBytes += decodedBytes;
      ownsFrame = false;
      this.#drainBufferedFrames();
      this.#pump();
    } catch (error) {
      if (ownsFrame) this.#closeFrame(frame);
      this.#fail(
        normalizeCoreError(
          error,
          "DECODER_OUTPUT_INVALID",
          "decoder output validation failed",
          true
        ),
        null
      );
    }
  }

  #drainBufferedFrames(): void {
    const limits = this.#limits;
    if (limits === null || this.#failure !== null || this.#disposed) return;
    while (this.#deliveryUnits.length > 0) {
      const unit = this.#deliveryUnits[0]!;
      if (unit.retired) {
        this.#deliveryUnits.shift();
        continue;
      }
      const buffered = unit.buffered.get(unit.nextPresentationIndex);
      if (buffered === undefined) return;
      if (this.#credits.count >= limits.maxOutstandingFrames) return;

      unit.buffered.delete(unit.nextPresentationIndex);
      this.#bufferedFrameCount -= 1;
      this.#bufferedDecodedBytes -= buffered.decodedBytes;
      const frameId = this.#credits.lease(
        unit.generation,
        buffered.decodedBytes,
        limits.maxDecodedBytes - this.#bufferedDecodedBytes
      );
      try {
        this.#emitEvent(
          {
            type: "frame",
            protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
            frameId,
            generation: unit.generation,
            ordinal: unit.presentationOrdinalBase + buffered.presentationIndex,
            unitId: unit.unitId,
            unitInstance: unit.unitInstance,
            unitFrame: buffered.presentationIndex,
            decodeIndex: buffered.decodeIndex,
            timestamp: buffered.timestamp,
            duration: buffered.duration,
            outputCallbackMicroseconds: buffered.outputCallbackMicroseconds,
            decodedBytes: buffered.decodedBytes,
            frame: buffered.frame
          },
          [buffered.frame]
        );
      } catch (error) {
        this.#credits.revoke(frameId);
        this.#closeFrame(buffered.frame);
        this.#fail(
          normalizeCoreError(
            error,
            "TRANSPORT_FAILED",
            "failed to transfer decoded frame",
            true
          ),
          null
        );
        return;
      }
      this.#metrics.deliveredFrames += 1;
      unit.nextPresentationIndex += 1;
      if (unit.nextPresentationIndex === unit.unitFrameCount) {
        this.#deliveryUnits.shift();
      }
    }
  }

  #retirePendingBefore(generation: number): void {
    let write = 0;
    for (const pending of this.#pending) {
      if (pending.generation >= generation) {
        this.#pending[write] = pending;
        write += 1;
      }
    }
    this.#pending.length = write;
  }

  #retirePendingGeneration(generation: number): void {
    let write = 0;
    for (const pending of this.#pending) {
      if (pending.generation !== generation) {
        this.#pending[write] = pending;
        write += 1;
      }
    }
    this.#pending.length = write;
  }

  #retirePresentationBefore(generation: number): void {
    const generations = new Set<number>();
    for (const unit of this.#deliveryUnits) {
      if (unit.generation < generation) generations.add(unit.generation);
    }
    if (
      this.#nativeUnit !== null &&
      this.#nativeUnit.generation < generation
    ) {
      generations.add(this.#nativeUnit.generation);
    }
    for (const retired of generations) {
      this.#retirePresentationGeneration(retired);
    }
  }

  #retirePresentationGeneration(generation: number): void {
    for (const unit of this.#deliveryUnits) {
      if (unit.generation !== generation) continue;
      unit.retired = true;
      for (const buffered of unit.buffered.values()) {
        this.#bufferedFrameCount -= 1;
        this.#bufferedDecodedBytes -= buffered.decodedBytes;
        this.#metrics.staleFrames += 1;
        this.#closeFrame(buffered.frame);
      }
      unit.buffered.clear();
    }
    let write = 0;
    for (const unit of this.#deliveryUnits) {
      if (unit.generation !== generation) {
        this.#deliveryUnits[write] = unit;
        write += 1;
      }
    }
    this.#deliveryUnits.length = write;
    if (
      this.#nativeUnit !== null &&
      this.#nativeUnit.generation === generation
    ) {
      this.#nativeUnit.retired = true;
      if (this.#flushingUnit === null) this.#startFlush(this.#nativeUnit);
    }
  }

  #pendingDisplayedFrameCount(): number {
    let count = 0;
    for (const pending of this.#pending) {
      count += pending.sample.displayedFrameCount;
    }
    return count;
  }

  #expectedForUnit(unit: SubmittedUnit): number {
    let count = 0;
    for (const expected of this.#expectedByTimestamp.values()) {
      if (expected.unit === unit) count += 1;
    }
    return count;
  }

  #dispose(requestId: number): void {
    if (!this.#disposed) {
      this.#disposed = true;
      this.#activeGeneration = null;
      this.#clearOwnedState();
      this.#sequence.clearActive();
      this.#credits.clear();
      this.#closeDecoder();
    }
    this.#emit({
      type: "disposed",
      protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
      requestId
    });
  }

  #fail(error: DecoderWorkerCoreError, requestId: number | null): void {
    if (this.#failure !== null || this.#disposed) return;
    this.#failure = error;
    this.#metrics.errors += 1;
    this.#activeGeneration = null;
    this.#clearOwnedState();
    this.#sequence.clearActive();
    this.#credits.clear();
    this.#closeDecoder();
    this.#emitError(requestId, error);
  }

  #clearOwnedState(): void {
    this.#pending.length = 0;
    this.#expectedByTimestamp.clear();
    for (const unit of this.#deliveryUnits) {
      for (const buffered of unit.buffered.values()) {
        this.#closeFrame(buffered.frame);
      }
      unit.buffered.clear();
    }
    this.#deliveryUnits.length = 0;
    this.#nativeUnit = null;
    this.#flushingUnit = null;
    this.#bufferedFrameCount = 0;
    this.#bufferedDecodedBytes = 0;
  }

  #emitAck(
    requestId: number,
    operation: Extract<DecoderWorkerEvent, { type: "ack" }>["operation"]
  ): void {
    this.#emit({
      type: "ack",
      protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
      requestId,
      operation
    });
  }

  #emitError(requestId: number | null, error: DecoderWorkerCoreError): void {
    this.#metrics.errors += error.fatal && this.#failure === error ? 0 : 1;
    const event: DecoderWorkerErrorEvent = {
      type: "error",
      protocolVersion: DECODER_WORKER_PROTOCOL_VERSION,
      requestId,
      code: error.code,
      message: error.message,
      fatal: error.fatal
    };
    this.#emit(event);
  }

  #emit(event: DecoderWorkerEvent): void {
    try {
      this.#emitEvent(event);
    } catch (error) {
      if (this.#failure === null && !this.#disposed) {
        this.#fail(
          normalizeCoreError(
            error,
            "TRANSPORT_FAILED",
            "decoder worker transport failed",
            true
          ),
          null
        );
      }
    }
  }

  #assertConfigured(): void {
    if (
      this.#decoder === null ||
      this.#expectedOutput === null ||
      this.#limits === null
    ) {
      throw new DecoderWorkerCoreError(
        "NOT_CONFIGURED",
        "decoder worker must be configured before use"
      );
    }
  }

  #requireExpectedOutput(): DecoderWorkerOutputExpectation {
    const expected = this.#expectedOutput;
    if (expected === null) {
      throw new DecoderWorkerCoreError(
        "NOT_CONFIGURED",
        "decoder output expectation is unavailable",
        true
      );
    }
    return expected;
  }

  #requireLimits(): DecoderWorkerLimits {
    const limits = this.#limits;
    if (limits === null) {
      throw new DecoderWorkerCoreError(
        "NOT_CONFIGURED",
        "decoder limits are unavailable",
        true
      );
    }
    return limits;
  }

  #readDecodeQueueSize(): number {
    if (this.#decoder === null || this.#decoderClosed) return 0;
    const size = this.#decoder.decodeQueueSize;
    if (!Number.isSafeInteger(size) || size < 0) {
      this.#fail(
        new DecoderWorkerCoreError(
          "DECODER_OUTPUT_INVALID",
          "WebCodecs reported an invalid decodeQueueSize",
          true
        ),
        null
      );
      return 0;
    }
    return size;
  }

  #closeFrame(frame: VideoFrame): void {
    try {
      frame.close();
    } finally {
      this.#metrics.closedFrames += 1;
    }
  }

  #closeDecoder(): void {
    if (this.#decoder === null || this.#decoderClosed) return;
    this.#decoderClosed = true;
    try {
      this.#decoder.close();
    } catch {
      // Decoder closure is best effort after a terminal failure.
    }
  }
}

function createSubmittedUnit(pending: PendingSample): SubmittedUnit {
  const sample = pending.sample;
  return {
    generation: pending.generation,
    unitId: sample.unitId,
    unitInstance: sample.unitInstance,
    unitChunkCount: sample.unitChunkCount,
    unitFrameCount: sample.unitFrameCount,
    presentationOrdinalBase: sample.presentationOrdinalBase,
    buffered: new Map<number, BufferedFrame>(),
    nextPresentationIndex: 0,
    retired: false
  };
}

function sameUnit(unit: SubmittedUnit, pending: PendingSample): boolean {
  const sample = pending.sample;
  return pending.generation === unit.generation &&
    sample.unitId === unit.unitId &&
    sample.unitInstance === unit.unitInstance &&
    sample.unitChunkCount === unit.unitChunkCount &&
    sample.unitFrameCount === unit.unitFrameCount &&
    sample.presentationOrdinalBase === unit.presentationOrdinalBase;
}

function sumDisplayedFrames(samples: readonly DecoderWorkerSample[]): number {
  let count = 0;
  for (const sample of samples) {
    count += sample.displayedFrameCount;
    if (!Number.isSafeInteger(count)) {
      throw new DecoderWorkerCoreError(
        "PROTOCOL_ERROR",
        "decode batch displayed-frame count is unsafe",
        true
      );
    }
  }
  return count;
}

function workerClockMicroseconds(): number {
  const value = Math.floor(
    performance.timeOrigin * 1_000 + performance.now() * 1_000
  );
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new DecoderWorkerCoreError(
      "DECODER_OUTPUT_INVALID",
      "worker output callback clock is invalid",
      true
    );
  }
  return value;
}

function defaultDecoderFactory(init: VideoDecoderInit): WorkerVideoDecoderAdapter {
  const decoder = new VideoDecoder(init);
  let dequeue: (() => void) | undefined;
  return {
    get decodeQueueSize(): number {
      return decoder.decodeQueueSize;
    },
    setDequeueCallback(callback): void {
      if (dequeue !== undefined) {
        decoder.removeEventListener("dequeue", dequeue);
      }
      dequeue = callback;
      decoder.addEventListener("dequeue", callback);
    },
    configure(config): void {
      decoder.configure(config);
    },
    decode(chunk): void {
      decoder.decode(chunk);
    },
    flush(): Promise<void> {
      return decoder.flush();
    },
    close(): void {
      if (dequeue !== undefined) {
        decoder.removeEventListener("dequeue", dequeue);
        dequeue = undefined;
      }
      decoder.close();
    }
  };
}

function defaultChunkFactory(init: EncodedVideoChunkInit): EncodedVideoChunk {
  return new EncodedVideoChunk(init);
}

async function defaultSupportProbe(
  config: VideoDecoderConfig
): Promise<VideoDecoderSupport> {
  return VideoDecoder.isConfigSupported(config);
}
