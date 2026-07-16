import {
  DecoderWorkerCoreError,
  expectedTimestamp,
  validateSampleShape
} from "./core-validation.js";
import { type DecoderWorkerSample } from "./protocol.js";

interface UnitSequence {
  readonly unitId: string;
  readonly unitInstance: number;
  readonly unitChunkCount: number;
  readonly unitFrameCount: number;
  readonly presentationOrdinalBase: number;
  readonly seenPresentationIndices: Set<number>;
  readonly seenTimestamps: Set<number>;
  nextDecodeIndex: number;
  displayedFrameCount: number;
}

/** Owns generation-local independent-unit and decode-order continuity. */
export class DecoderSampleSequence {
  #activeGeneration: number | null = null;
  #nextUnitInstance = 0;
  #activeUnit: UnitSequence | null = null;
  #acceptedChunks = 0;

  public get acceptedChunks(): number {
    return this.#acceptedChunks;
  }

  public activate(generation: number): void {
    this.#activeGeneration = generation;
    this.#nextUnitInstance = 0;
    this.#activeUnit = null;
  }

  public abort(generation: number): void {
    if (this.#activeGeneration === generation) {
      this.#activeGeneration = null;
      this.#activeUnit = null;
    }
  }

  public clearActive(): void {
    this.#activeGeneration = null;
    this.#activeUnit = null;
  }

  /** Validates the entire batch atomically before advancing the sequence. */
  public accept(
    generation: number,
    samples: readonly DecoderWorkerSample[]
  ): void {
    if (generation !== this.#activeGeneration) {
      throw new DecoderWorkerCoreError(
        "GENERATION_MISMATCH",
        "decode submission does not target the active generation"
      );
    }

    let nextUnitInstance = this.#nextUnitInstance;
    let activeUnit = cloneUnit(this.#activeUnit);
    for (const sample of samples) {
      validateSampleShape(sample);
      if (activeUnit === null) {
        if (sample.decodeIndex !== 0) {
          throw protocolError("every unit occurrence must begin at decodeIndex zero");
        }
        if (sample.unitInstance !== nextUnitInstance) {
          throw protocolError(
            `unitInstance must be ${String(nextUnitInstance)}`
          );
        }
        if (!sample.randomAccess) {
          throw protocolError("every unit occurrence must begin at random access");
        }
        if (nextUnitInstance >= Number.MAX_SAFE_INTEGER) {
          throw protocolError("unitInstance leaves no safe successor");
        }
        activeUnit = {
          unitId: sample.unitId,
          unitInstance: sample.unitInstance,
          unitChunkCount: sample.unitChunkCount,
          unitFrameCount: sample.unitFrameCount,
          presentationOrdinalBase: sample.presentationOrdinalBase,
          seenPresentationIndices: new Set<number>(),
          seenTimestamps: new Set<number>(),
          nextDecodeIndex: 0,
          displayedFrameCount: 0
        };
        nextUnitInstance += 1;
      }
      validateUnitRelation(activeUnit, sample);
      for (let index = 0; index < sample.presentationIndices.length; index += 1) {
        const presentationIndex = sample.presentationIndices[index]!;
        if (activeUnit.seenPresentationIndices.has(presentationIndex)) {
          throw protocolError(
            "unit presentation indices must be unique and complete"
          );
        }
        const timestamp = expectedTimestamp(sample, index);
        if (activeUnit.seenTimestamps.has(timestamp)) {
          throw protocolError("unit presentation timestamps must be unique");
        }
        activeUnit.seenPresentationIndices.add(presentationIndex);
        activeUnit.seenTimestamps.add(timestamp);
      }
      activeUnit.displayedFrameCount += sample.displayedFrameCount;
      if (!Number.isSafeInteger(activeUnit.displayedFrameCount)) {
        throw protocolError("unit displayed-frame count is unsafe");
      }
      activeUnit.nextDecodeIndex += 1;
      if (activeUnit.nextDecodeIndex === activeUnit.unitChunkCount) {
        if (
          activeUnit.displayedFrameCount !== activeUnit.unitFrameCount ||
          activeUnit.seenPresentationIndices.size !== activeUnit.unitFrameCount
        ) {
          throw protocolError(
            "unit displayed-frame metadata is incomplete"
          );
        }
        activeUnit = null;
      }
    }

    if (this.#acceptedChunks > Number.MAX_SAFE_INTEGER - samples.length) {
      throw protocolError("accepted chunk count exceeds safe integers");
    }
    this.#nextUnitInstance = nextUnitInstance;
    this.#activeUnit = activeUnit;
    this.#acceptedChunks += samples.length;
  }
}

function validateUnitRelation(
  unit: UnitSequence,
  sample: DecoderWorkerSample
): void {
  if (
    sample.unitId !== unit.unitId ||
    sample.unitInstance !== unit.unitInstance ||
    sample.unitChunkCount !== unit.unitChunkCount ||
    sample.unitFrameCount !== unit.unitFrameCount ||
    sample.presentationOrdinalBase !== unit.presentationOrdinalBase
  ) {
    throw protocolError(
      "decode chunks in one unit occurrence must share exact unit metadata"
    );
  }
  if (sample.decodeIndex !== unit.nextDecodeIndex) {
    throw protocolError(
      `decodeIndex must be ${String(unit.nextDecodeIndex)}`
    );
  }
}

function cloneUnit(value: UnitSequence | null): UnitSequence | null {
  return value === null
    ? null
    : {
        ...value,
        seenPresentationIndices: new Set(value.seenPresentationIndices),
        seenTimestamps: new Set(value.seenTimestamps)
      };
}

function protocolError(message: string): DecoderWorkerCoreError {
  return new DecoderWorkerCoreError("PROTOCOL_ERROR", message, true);
}
