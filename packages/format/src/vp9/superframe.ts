import { FormatError } from "../errors.js";

const SUPERFRAME_MARKER_MASK = 0xe0;
const SUPERFRAME_MARKER = 0xc0;

/** Split a VP9 packet into owned coded frames, including hidden alt-ref frames. */
export function splitVp9Superframe(
  bytes: Uint8Array,
  path = "vp9"
): readonly Uint8Array[] {
  requireVp9(bytes instanceof Uint8Array, path, "packet must be bytes");
  requireVp9(bytes.byteLength > 0, path, "packet is empty");
  const marker = bytes[bytes.byteLength - 1];
  if (marker === undefined || (marker & SUPERFRAME_MARKER_MASK) !== SUPERFRAME_MARKER) {
    return Object.freeze([bytes.slice()]);
  }

  const frameCount = (marker & 0x07) + 1;
  const magnitude = ((marker >> 3) & 0x03) + 1;
  const indexBytes = 2 + frameCount * magnitude;
  requireVp9(bytes.byteLength > indexBytes, path, "superframe index is truncated");
  const indexStart = bytes.byteLength - indexBytes;
  requireVp9(bytes[indexStart] === marker, path, "superframe markers disagree");

  const sizes: number[] = [];
  let cursor = indexStart + 1;
  let payloadBytes = 0;
  for (let frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    let size = 0;
    let multiplier = 1;
    for (let byteIndex = 0; byteIndex < magnitude; byteIndex += 1) {
      const byte = bytes[cursor];
      requireVp9(byte !== undefined, path, "superframe size is truncated");
      size += byte * multiplier;
      multiplier *= 256;
      cursor += 1;
    }
    requireVp9(size > 0, path, "superframe contains an empty coded frame");
    requireVp9(
      Number.isSafeInteger(payloadBytes + size),
      path,
      "superframe payload size is unsafe"
    );
    payloadBytes += size;
    sizes.push(size);
  }
  requireVp9(payloadBytes === indexStart, path, "superframe sizes do not cover the payload");

  const frames: Uint8Array[] = [];
  cursor = 0;
  for (const size of sizes) {
    frames.push(bytes.slice(cursor, cursor + size));
    cursor += size;
  }
  return Object.freeze(frames);
}

function requireVp9(
  condition: boolean,
  path: string,
  message: string
): asserts condition {
  if (!condition) {
    throw new FormatError("PROFILE_INVALID", `VP9 ${message}`, { path });
  }
}
