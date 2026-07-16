import { FormatError } from "../errors.js";
import { deriveVp9Codec, type Vp9Codec } from "./codec.js";
import { parseVp9FrameHeader, type Vp9FrameHeader } from "./frame-header.js";
import { splitVp9Superframe } from "./superframe.js";

export interface Vp9PacketInput {
  readonly bytes: Uint8Array;
  readonly key: boolean;
  readonly timestamp: number;
}

export interface Vp9UnitInput {
  readonly id: string;
  readonly packets: readonly Vp9PacketInput[];
  readonly expectedDisplayedFrames: number;
}

export interface Vp9RenditionInspectionInput {
  readonly width: number;
  readonly height: number;
  readonly frameRate: { readonly numerator: number; readonly denominator: number };
  readonly averageBitrate: number;
  readonly units: readonly Vp9UnitInput[];
}

export interface Vp9PacketInspection {
  readonly timestamp: number;
  readonly chunkType: "key" | "delta";
  readonly codedFrames: readonly Vp9FrameHeader[];
  readonly displayedFrameCount: number;
}

export interface Vp9UnitInspection {
  readonly id: string;
  readonly packets: readonly Vp9PacketInspection[];
  readonly displayedFrameCount: number;
}

export interface Vp9RenditionInspection {
  readonly codec: Vp9Codec;
  readonly width: number;
  readonly height: number;
  readonly bitDepth: 8;
  readonly units: readonly Vp9UnitInspection[];
}

/** Inspect profile-0 VP9 packets while preserving hidden/reference frames. */
export function inspectVp9Rendition(
  input: Readonly<Vp9RenditionInspectionInput>
): Readonly<Vp9RenditionInspection> {
  requirePositiveInteger(input.width, "width");
  requirePositiveInteger(input.height, "height");
  requirePositiveInteger(input.frameRate?.numerator, "frameRate.numerator");
  requirePositiveInteger(input.frameRate?.denominator, "frameRate.denominator");
  requirePositiveInteger(input.averageBitrate, "averageBitrate");
  if (!Array.isArray(input.units) || input.units.length === 0) {
    invalid("VP9 rendition requires at least one unit", "units");
  }

  const unitIds = new Set<string>();
  const units: Vp9UnitInspection[] = [];
  let maximumCodedFramesPerDisplayedFrame = 1;
  for (let unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
    const unit = input.units[unitIndex];
    const unitPath = `units[${String(unitIndex)}]`;
    if (unit === undefined || typeof unit.id !== "string" || unit.id.length === 0) {
      invalid("VP9 unit id is invalid", `${unitPath}.id`);
    }
    if (unitIds.has(unit.id)) invalid("VP9 unit id is duplicated", `${unitPath}.id`);
    unitIds.add(unit.id);
    requirePositiveInteger(unit.expectedDisplayedFrames, `${unitPath}.expectedDisplayedFrames`);
    if (!Array.isArray(unit.packets) || unit.packets.length === 0) {
      invalid("VP9 unit requires packets", `${unitPath}.packets`);
    }

    const packets: Vp9PacketInspection[] = [];
    let displayedFrameCount = 0;
    let codedFrameCount = 0;
    for (let packetIndex = 0; packetIndex < unit.packets.length; packetIndex += 1) {
      const packet = unit.packets[packetIndex];
      const packetPath = `${unitPath}.packets[${String(packetIndex)}]`;
      if (packet === undefined || !(packet.bytes instanceof Uint8Array)) {
        invalid("VP9 packet bytes are invalid", `${packetPath}.bytes`);
      }
      if (!Number.isSafeInteger(packet.timestamp) || packet.timestamp < 0) {
        invalid("VP9 packet timestamp is invalid", `${packetPath}.timestamp`);
      }
      const codedFrames = splitVp9Superframe(packet.bytes, `${packetPath}.bytes`)
        .map((frame, frameIndex) => parseVp9FrameHeader(
          frame,
          `${packetPath}.codedFrames[${String(frameIndex)}]`
        ));
      const packetDisplayedFrames = codedFrames.reduce(
        (total, frame) => total + frame.displayedFrameCount,
        0
      );
      const first = codedFrames[0];
      if (first === undefined) invalid("VP9 packet contains no coded frames", packetPath);
      if (packetIndex === 0 && !first.key) {
        invalid("VP9 unit must start with a key frame", packetPath);
      }
      if (packet.key !== first.key) {
        invalid("VP9 chunk key assertion disagrees with the bitstream", `${packetPath}.key`);
      }
      displayedFrameCount += packetDisplayedFrames;
      codedFrameCount += codedFrames.length;
      packets.push(Object.freeze({
        timestamp: packet.timestamp,
        chunkType: first.key ? "key" : "delta",
        codedFrames: Object.freeze(codedFrames),
        displayedFrameCount: packetDisplayedFrames
      }));
    }
    if (displayedFrameCount !== unit.expectedDisplayedFrames) {
      invalid("VP9 displayed frame count disagrees with the authored unit", unitPath);
    }
    maximumCodedFramesPerDisplayedFrame = Math.max(
      maximumCodedFramesPerDisplayedFrame,
      codedFrameCount / displayedFrameCount
    );
    units.push(Object.freeze({
      id: unit.id,
      packets: Object.freeze(packets),
      displayedFrameCount
    }));
  }

  const displayFramesPerSecond = input.frameRate.numerator / input.frameRate.denominator;
  const codec = deriveVp9Codec({
    width: input.width,
    height: input.height,
    codedFramesPerSecond: displayFramesPerSecond * maximumCodedFramesPerDisplayedFrame,
    averageBitrate: input.averageBitrate
  });
  return Object.freeze({
    codec,
    width: input.width,
    height: input.height,
    bitDepth: 8,
    units: Object.freeze(units)
  });
}

function requirePositiveInteger(value: number, path: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    invalid("VP9 value must be a positive safe integer", path);
  }
}

function invalid(message: string, path: string): never {
  throw new FormatError("PROFILE_INVALID", message, { path });
}
