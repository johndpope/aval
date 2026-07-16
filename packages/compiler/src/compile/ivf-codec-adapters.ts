import {
  inspectAv1Rendition,
  inspectVp9Rendition,
  parseAv1FrameHeaderPrefix,
  parseAv1LowOverheadObus,
  parseAv1SequenceHeader,
  parseVp9FrameHeader,
  splitVp9Superframe,
  AV1_OBU_FRAME,
  AV1_OBU_FRAME_HEADER,
  AV1_OBU_SEQUENCE_HEADER,
  type Av1RenditionInspection,
  type Av1SequenceHeader,
  type Vp9RenditionInspection
} from "@pixel-point/aval-format";

import { CompilerError } from "../diagnostics.js";
import type { IvfFrame } from "../ffmpeg/ivf.js";
import type { Rational } from "../model.js";

export interface IvfEncodedUnitInput {
  readonly id: string;
  readonly expectedDisplayedFrames: number;
  readonly packets: readonly IvfFrame[];
}

export interface PreparedVideoChunk {
  readonly bytes: Uint8Array;
  readonly presentationTimestamp: number;
  readonly duration: number;
  readonly randomAccess: boolean;
  readonly displayedFrameCount: number;
}

export interface PreparedIvfUnit {
  readonly id: string;
  readonly frameCount: number;
  readonly chunks: readonly PreparedVideoChunk[];
}

export interface PreparedVp9Rendition {
  readonly codec: string;
  readonly bitDepth: 8;
  readonly bitrate: { readonly average: number; readonly peak: number };
  readonly units: readonly PreparedIvfUnit[];
  readonly inspection: Readonly<Vp9RenditionInspection>;
}

export interface PreparedAv1Rendition {
  readonly codec: string;
  readonly bitDepth: 8 | 10;
  readonly bitrate: { readonly average: number; readonly peak: number };
  readonly units: readonly PreparedIvfUnit[];
  readonly inspection: Readonly<Av1RenditionInspection>;
}

/** Inspect all independently encoded VP9 units and lower decode-order chunks. */
export function prepareVp9Rendition(input: Readonly<{
  readonly width: number;
  readonly height: number;
  readonly frameRate: Readonly<Rational>;
  readonly units: readonly IvfEncodedUnitInput[];
}>): Readonly<PreparedVp9Rendition> {
  const totalFrames = expectedFrameTotal(input.units);
  const totalBytes = encodedByteTotal(input.units);
  const measuredAverageBitrate = deriveAverageBitrate(
    totalBytes,
    totalFrames,
    input.frameRate
  );
  const packetInputs = input.units.map((unit) => Object.freeze({
    id: unit.id,
    expectedDisplayedFrames: unit.expectedDisplayedFrames,
    packets: Object.freeze(unit.packets.map((packet) => {
      const first = splitVp9Superframe(packet.bytes)[0];
      if (first === undefined) invalid("VP9 packet contains no coded frame", unit.id);
      return Object.freeze({
        bytes: packet.bytes,
        timestamp: packet.timestamp,
        key: parseVp9FrameHeader(first).key
      });
    }))
  }));
  const inspection = inspectVp9Rendition({
    width: input.width,
    height: input.height,
    frameRate: input.frameRate,
    averageBitrate: measuredAverageBitrate,
    units: packetInputs
  });
  const units = input.units.map((unit, unitIndex) => {
    const inspected = inspection.units[unitIndex];
    if (inspected === undefined || inspected.packets.length !== unit.packets.length) {
      invalid("VP9 inspection result does not match the encoded packets", unit.id);
    }
    return Object.freeze({
      id: unit.id,
      frameCount: unit.expectedDisplayedFrames,
      chunks: Object.freeze(unit.packets.map((packet, packetIndex) => {
        const summary = inspected.packets[packetIndex]!;
        return preparedChunk(packet, summary.chunkType === "key", summary.displayedFrameCount);
      }))
    });
  });
  return Object.freeze({
    codec: inspection.codec,
    bitDepth: 8 as const,
    bitrate: Object.freeze({
      average: measuredAverageBitrate,
      peak: measuredAverageBitrate
    }),
    units: Object.freeze(units),
    inspection
  });
}

/** Inspect all independently encoded AV1 units and lower decode-order chunks. */
export function prepareAv1Rendition(input: Readonly<{
  readonly width: number;
  readonly height: number;
  readonly bitDepth: 8 | 10;
  readonly frameRate: Readonly<Rational>;
  readonly units: readonly IvfEncodedUnitInput[];
}>): Readonly<PreparedAv1Rendition> {
  const totalFrames = expectedFrameTotal(input.units);
  const totalBytes = encodedByteTotal(input.units);
  const average = deriveAverageBitrate(totalBytes, totalFrames, input.frameRate);
  let sequence: Readonly<Av1SequenceHeader> | undefined;
  const chunkInputs = input.units.map((unit) => Object.freeze({
    id: unit.id,
    expectedDisplayedFrames: unit.expectedDisplayedFrames,
    chunks: Object.freeze(unit.packets.map((packet) => {
      const obus = parseAv1LowOverheadObus(packet.bytes);
      for (const obu of obus) {
        if (obu.type === AV1_OBU_SEQUENCE_HEADER) {
          sequence = parseAv1SequenceHeader(obu.payload);
        }
      }
      if (sequence === undefined) {
        invalid("AV1 packet contains frame data before a sequence header", unit.id);
      }
      const key = obus
        .filter((obu) => obu.type === AV1_OBU_FRAME || obu.type === AV1_OBU_FRAME_HEADER)
        .some((obu) => parseAv1FrameHeaderPrefix(obu.payload, sequence!).key);
      return Object.freeze({
        bytes: packet.bytes,
        timestamp: packet.timestamp,
        key
      });
    }))
  }));
  const inspection = inspectAv1Rendition({
    width: input.width,
    height: input.height,
    bitDepth: input.bitDepth,
    units: chunkInputs
  });
  const units = input.units.map((unit, unitIndex) => {
    const inspected = inspection.units[unitIndex];
    if (inspected === undefined || inspected.chunks.length !== unit.packets.length) {
      invalid("AV1 inspection result does not match the encoded packets", unit.id);
    }
    return Object.freeze({
      id: unit.id,
      frameCount: unit.expectedDisplayedFrames,
      chunks: Object.freeze(unit.packets.map((packet, packetIndex) => {
        const summary = inspected.chunks[packetIndex]!;
        return preparedChunk(packet, summary.chunkType === "key", summary.displayedFrameCount);
      }))
    });
  });
  return Object.freeze({
    codec: inspection.codec,
    bitDepth: input.bitDepth,
    bitrate: Object.freeze({ average, peak: average }),
    units: Object.freeze(units),
    inspection
  });
}

function preparedChunk(
  packet: Readonly<IvfFrame>,
  randomAccess: boolean,
  displayedFrameCount: number
): Readonly<PreparedVideoChunk> {
  return Object.freeze({
    bytes: packet.bytes.slice(),
    presentationTimestamp: packet.timestamp,
    duration: displayedFrameCount > 0 ? 1 : 0,
    randomAccess,
    displayedFrameCount
  });
}

function expectedFrameTotal(units: readonly IvfEncodedUnitInput[]): number {
  if (!Array.isArray(units) || units.length < 1) {
    throw new CompilerError("INPUT_INVALID", "Encoded rendition requires units");
  }
  let total = 0;
  const ids = new Set<string>();
  for (const unit of units) {
    if (typeof unit?.id !== "string" || unit.id.length === 0 || ids.has(unit.id)) {
      throw new CompilerError("INPUT_INVALID", "Encoded unit identity is invalid or duplicated");
    }
    ids.add(unit.id);
    if (!Number.isSafeInteger(unit.expectedDisplayedFrames) || unit.expectedDisplayedFrames < 1) {
      invalid("Encoded unit frame count must be a positive safe integer", unit.id);
    }
    if (!Array.isArray(unit.packets) || unit.packets.length < 1) {
      invalid("Encoded unit requires packets", unit.id);
    }
    total = checkedAdd(total, unit.expectedDisplayedFrames, "encoded frame count");
  }
  return total;
}

function encodedByteTotal(units: readonly IvfEncodedUnitInput[]): number {
  let total = 0;
  for (const unit of units) {
    for (const packet of unit.packets) {
      if (!(packet?.bytes instanceof Uint8Array) || packet.bytes.byteLength < 1) {
        invalid("Encoded packet bytes are invalid", unit.id);
      }
      if (!Number.isSafeInteger(packet.timestamp) || packet.timestamp < 0) {
        invalid("Encoded packet timestamp is invalid", unit.id);
      }
      total = checkedAdd(total, packet.bytes.byteLength, "encoded byte count");
    }
  }
  return total;
}

function deriveAverageBitrate(
  bytes: number,
  frames: number,
  frameRate: Readonly<Rational>
): number {
  if (
    !Number.isSafeInteger(frameRate?.numerator) ||
    !Number.isSafeInteger(frameRate?.denominator) ||
    frameRate.numerator < 1 ||
    frameRate.denominator < 1
  ) {
    throw new CompilerError("INPUT_INVALID", "Encoded rendition frame rate is invalid");
  }
  const numerator = bytes * 8 * frameRate.numerator;
  const denominator = frames * frameRate.denominator;
  if (!Number.isSafeInteger(numerator) || !Number.isSafeInteger(denominator)) {
    throw new CompilerError("OUTPUT_LIMIT", "Encoded rendition bitrate exceeds safe arithmetic");
  }
  return Math.max(1, Math.ceil(numerator / denominator));
}

function checkedAdd(left: number, right: number, label: string): number {
  const result = left + right;
  if (!Number.isSafeInteger(result) || result < 0) {
    throw new CompilerError("OUTPUT_LIMIT", `${label} exceeds safe arithmetic`);
  }
  return result;
}

function invalid(message: string, unit: string): never {
  throw new CompilerError("ASSET_INVALID", message, { unit });
}
