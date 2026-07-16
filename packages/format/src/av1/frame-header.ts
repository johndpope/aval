import { FormatError } from "../errors.js";
import { Av1BitReader } from "./bit-reader.js";
import type { Av1SequenceHeader } from "./sequence-header.js";

export type Av1FrameType = "key" | "inter" | "intra-only" | "switch" | "show-existing";

export interface Av1FrameHeaderPrefix {
  readonly frameType: Av1FrameType;
  readonly key: boolean;
  readonly randomAccess: boolean;
  readonly showFrame: boolean;
  readonly showExistingFrame: boolean;
  readonly displayedFrameCount: 0 | 1;
}

/** Parse the frame-header prefix that determines random access and display. */
export function parseAv1FrameHeaderPrefix(
  payload: Uint8Array,
  sequence: Readonly<Av1SequenceHeader>,
  path = "av1.frameHeader"
): Readonly<Av1FrameHeaderPrefix> {
  if (!(payload instanceof Uint8Array) || payload.byteLength === 0) {
    invalid("frame header is empty", path);
  }
  if (sequence.reducedStillPictureHeader) {
    return Object.freeze({
      frameType: "key",
      key: true,
      randomAccess: true,
      showFrame: true,
      showExistingFrame: false,
      displayedFrameCount: 1
    });
  }

  const reader = new Av1BitReader(payload, path);
  const showExistingFrame = reader.readBit("show_existing_frame");
  if (showExistingFrame) {
    reader.readBits(3, "frame_to_show_map_idx");
    return Object.freeze({
      frameType: "show-existing",
      key: false,
      randomAccess: false,
      showFrame: true,
      showExistingFrame: true,
      displayedFrameCount: 1
    });
  }

  const rawFrameType = reader.readBits(2, "frame_type");
  const frameType = (["key", "inter", "intra-only", "switch"] as const)[rawFrameType];
  if (frameType === undefined) invalid("frame type is invalid", path);
  const showFrame = reader.readBit("show_frame");
  if (!showFrame) reader.readBit("showable_frame");
  return Object.freeze({
    frameType,
    key: frameType === "key",
    randomAccess: frameType === "key" && showFrame,
    showFrame,
    showExistingFrame: false,
    displayedFrameCount: showFrame ? 1 : 0
  });
}

function invalid(message: string, path: string): never {
  throw new FormatError("PROFILE_INVALID", `AV1 ${message}`, { path });
}
