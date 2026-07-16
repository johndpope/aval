import { CompilerError } from "../diagnostics.js";

const CHANNELS_PER_PIXEL = 4;
const BYTES_PER_RGBA64_PIXEL = 8;
const UINT16_MAXIMUM = 65_535;

/** Expand RGBA8 channels exactly into the canonical full-range RGBA16 domain. */
export function expandRgba8ToRgba16(input: Uint8Array): Uint16Array {
  if (!(input instanceof Uint8Array) || input.byteLength % CHANNELS_PER_PIXEL !== 0) {
    throw invalid("RGBA8 input must contain complete four-channel pixels");
  }
  const output = new Uint16Array(input.byteLength);
  for (let index = 0; index < input.byteLength; index += 1) {
    output[index] = input[index]! * 257;
  }
  return output;
}

/** Downconvert canonical RGBA16 with deterministic nearest rounding. */
export function downconvertRgba16ToRgba8(input: Uint16Array): Uint8Array {
  requireRgba16(input);
  const output = new Uint8Array(input.length);
  for (let index = 0; index < input.length; index += 1) {
    output[index] = Math.floor((input[index]! * 255 + 32_767) / UINT16_MAXIMUM);
  }
  return output;
}

/** Decode FFmpeg rgba64le bytes without relying on host typed-array endianness. */
export function decodeRgba64Le(input: Uint8Array): Uint16Array {
  if (
    !(input instanceof Uint8Array) ||
    input.byteLength % BYTES_PER_RGBA64_PIXEL !== 0
  ) {
    throw invalid("RGBA64LE input must contain complete eight-byte pixels");
  }
  const output = new Uint16Array(input.byteLength / 2);
  for (let offset = 0; offset < input.byteLength; offset += 2) {
    output[offset / 2] = input[offset]! | input[offset + 1]! << 8;
  }
  return output;
}

/** Encode canonical channels as explicit little-endian FFmpeg rgba64le bytes. */
export function encodeRgba64Le(input: Uint16Array): Uint8Array {
  requireRgba16(input);
  const output = new Uint8Array(checkedProduct(input.length, 2));
  for (let index = 0; index < input.length; index += 1) {
    const value = input[index]!;
    output[index * 2] = value & 0xff;
    output[index * 2 + 1] = value >>> 8;
  }
  return output;
}

function requireRgba16(input: Uint16Array): void {
  if (!(input instanceof Uint16Array) || input.length % CHANNELS_PER_PIXEL !== 0) {
    throw invalid("RGBA16 input must contain complete four-channel pixels");
  }
}

function checkedProduct(left: number, right: number): number {
  const result = left * right;
  if (!Number.isSafeInteger(result) || result < 0) {
    throw invalid("RGBA16 byte length exceeds the safe integer range");
  }
  return result;
}

function invalid(message: string): CompilerError {
  return new CompilerError("INPUT_INVALID", message, { phase: "pixel-pipeline" });
}
