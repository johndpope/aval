import { FormatError } from "../errors.js";
import { av1CodecFromSequence, type Av1Codec } from "./codec.js";
import { parseAv1FrameHeaderPrefix, type Av1FrameHeaderPrefix } from "./frame-header.js";
import {
  AV1_OBU_FRAME,
  AV1_OBU_FRAME_HEADER,
  AV1_OBU_SEQUENCE_HEADER,
  parseAv1LowOverheadObus
} from "./obu.js";
import { parseAv1SequenceHeader, type Av1SequenceHeader } from "./sequence-header.js";

export interface Av1ChunkInput {
  readonly bytes: Uint8Array;
  readonly key: boolean;
  readonly timestamp: number;
}

export interface Av1UnitInput {
  readonly id: string;
  readonly chunks: readonly Av1ChunkInput[];
  readonly expectedDisplayedFrames: number;
}

export interface Av1RenditionInspectionInput {
  readonly width: number;
  readonly height: number;
  readonly bitDepth: 8 | 10;
  readonly units: readonly Av1UnitInput[];
}

export interface Av1ChunkInspection {
  readonly timestamp: number;
  readonly chunkType: "key" | "delta";
  readonly frames: readonly Av1FrameHeaderPrefix[];
  readonly displayedFrameCount: number;
}

export interface Av1UnitInspection {
  readonly id: string;
  readonly chunks: readonly Av1ChunkInspection[];
  readonly displayedFrameCount: number;
}

export interface Av1RenditionInspection {
  readonly codec: Av1Codec;
  readonly sequence: Av1SequenceHeader;
  readonly units: readonly Av1UnitInspection[];
}

/** Inspect low-overhead AV1 temporal units, including hidden/show-existing frames. */
export function inspectAv1Rendition(
  input: Readonly<Av1RenditionInspectionInput>
): Readonly<Av1RenditionInspection> {
  requirePositiveInteger(input.width, "width");
  requirePositiveInteger(input.height, "height");
  if (input.bitDepth !== 8 && input.bitDepth !== 10) invalid("bit depth is invalid", "bitDepth");
  if (!Array.isArray(input.units) || input.units.length === 0) invalid("rendition requires units", "units");

  let stableSequence: Av1SequenceHeader | undefined;
  const unitIds = new Set<string>();
  const units: Av1UnitInspection[] = [];
  for (let unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
    const unit = input.units[unitIndex];
    const unitPath = `units[${String(unitIndex)}]`;
    if (unit === undefined || typeof unit.id !== "string" || unit.id.length === 0) {
      invalid("unit id is invalid", `${unitPath}.id`);
    }
    if (unitIds.has(unit.id)) invalid("unit id is duplicated", `${unitPath}.id`);
    unitIds.add(unit.id);
    requirePositiveInteger(unit.expectedDisplayedFrames, `${unitPath}.expectedDisplayedFrames`);
    if (!Array.isArray(unit.chunks) || unit.chunks.length === 0) invalid("unit requires chunks", `${unitPath}.chunks`);

    let displayedFrameCount = 0;
    const chunks: Av1ChunkInspection[] = [];
    for (let chunkIndex = 0; chunkIndex < unit.chunks.length; chunkIndex += 1) {
      const chunk = unit.chunks[chunkIndex];
      const chunkPath = `${unitPath}.chunks[${String(chunkIndex)}]`;
      if (chunk === undefined || !(chunk.bytes instanceof Uint8Array)) invalid("chunk bytes are invalid", `${chunkPath}.bytes`);
      if (!Number.isSafeInteger(chunk.timestamp) || chunk.timestamp < 0) invalid("chunk timestamp is invalid", `${chunkPath}.timestamp`);
      const obus = parseAv1LowOverheadObus(chunk.bytes, `${chunkPath}.bytes`);
      for (const [obuIndex, obu] of obus.entries()) {
        if (obu.type !== AV1_OBU_SEQUENCE_HEADER) continue;
        const sequence = parseAv1SequenceHeader(obu.payload, `${chunkPath}.obus[${String(obuIndex)}]`);
        if (stableSequence === undefined) {
          stableSequence = sequence;
          validateSequence(sequence, input);
        } else if (JSON.stringify(sequence) !== JSON.stringify(stableSequence)) {
          invalid("sequence header changes within the rendition", `${chunkPath}.obus[${String(obuIndex)}]`);
        }
      }
      if (stableSequence === undefined) invalid("frame data precedes the sequence header", chunkPath);
      const frames = obus
        .filter((obu) => obu.type === AV1_OBU_FRAME || obu.type === AV1_OBU_FRAME_HEADER)
        .map((obu, frameIndex) => parseAv1FrameHeaderPrefix(
          obu.payload,
          stableSequence!,
          `${chunkPath}.frames[${String(frameIndex)}]`
        ));
      if (frames.length === 0) invalid("chunk contains no frame header", chunkPath);
      const first = frames[0]!;
      if (chunkIndex === 0 && !first.randomAccess) invalid("unit must start at a shown key frame", chunkPath);
      if (chunk.key !== frames.some((frame) => frame.key)) {
        invalid("chunk key assertion disagrees with the bitstream", `${chunkPath}.key`);
      }
      const chunkDisplayedFrames = frames.reduce(
        (total, frame) => total + frame.displayedFrameCount,
        0
      );
      displayedFrameCount += chunkDisplayedFrames;
      chunks.push(Object.freeze({
        timestamp: chunk.timestamp,
        chunkType: chunk.key ? "key" : "delta",
        frames: Object.freeze(frames),
        displayedFrameCount: chunkDisplayedFrames
      }));
    }
    if (displayedFrameCount !== unit.expectedDisplayedFrames) {
      invalid("displayed frame count disagrees with the authored unit", unitPath);
    }
    units.push(Object.freeze({
      id: unit.id,
      chunks: Object.freeze(chunks),
      displayedFrameCount
    }));
  }
  if (stableSequence === undefined) invalid("rendition has no sequence header", "units");
  return Object.freeze({
    codec: av1CodecFromSequence(stableSequence),
    sequence: stableSequence,
    units: Object.freeze(units)
  });
}

function validateSequence(
  sequence: Readonly<Av1SequenceHeader>,
  input: Readonly<Av1RenditionInspectionInput>
): void {
  if (sequence.maxWidth !== input.width || sequence.maxHeight !== input.height) {
    invalid("sequence dimensions disagree with the rendition", "sequenceHeader");
  }
  if (sequence.bitDepth !== input.bitDepth) {
    invalid("sequence bit depth disagrees with the rendition", "sequenceHeader");
  }
}

function requirePositiveInteger(value: number, path: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) invalid("value must be a positive safe integer", path);
}

function invalid(message: string, path: string): never {
  throw new FormatError("PROFILE_INVALID", `AV1 ${message}`, { path });
}
