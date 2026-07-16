import { CompilerError } from "../diagnostics.js";
import { roundSignedRatio } from "./bt709-limited.js";

const LUMA_RED = 2_126;
const LUMA_GREEN = 7_152;
const LUMA_BLUE = 722;
const LUMA_SCALE = 10_000;
const RGBA_CHANNELS = 4;
const UINT16_MAXIMUM = 65_535;

export interface Rgba16ToYuv420Input {
  readonly width: number;
  readonly height: number;
  readonly bitDepth: 8 | 10;
}

/** Convert a complete RGBA16 frame to deterministic BT.709 limited YUV420. */
export function convertRgba16ToYuv420(
  rgba: Uint16Array,
  input: Readonly<Rgba16ToYuv420Input>
): Uint8Array {
  const { width, height, bitDepth } = validateInput(rgba, input);
  const samples = checkedProduct(width, height, 3) / 2;
  const bytesPerSample = bitDepth === 10 ? 2 : 1;
  const output = new Uint8Array(checkedProduct(samples, bytesPerSample));
  const yLength = width * height;
  const chromaLength = yLength / 4;
  const cbOffset = yLength;
  const crOffset = cbOffset + chromaLength;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const source = (y * width + x) * RGBA_CHANNELS;
      const value = luma(
        rgba[source]!,
        rgba[source + 1]!,
        rgba[source + 2]!,
        bitDepth
      );
      writeSample(output, y * width + x, value, bytesPerSample);
    }
  }

  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) {
      let blueDifference = 0;
      let redDifference = 0;
      for (let deltaY = 0; deltaY < 2; deltaY += 1) {
        for (let deltaX = 0; deltaX < 2; deltaX += 1) {
          const source = ((y + deltaY) * width + x + deltaX) * RGBA_CHANNELS;
          const red = rgba[source]!;
          const green = rgba[source + 1]!;
          const blue = rgba[source + 2]!;
          const weighted = weightedLuma(red, green, blue);
          blueDifference += LUMA_SCALE * blue - weighted;
          redDifference += LUMA_SCALE * red - weighted;
        }
      }
      const chroma = chromaSamples(blueDifference, redDifference, bitDepth);
      const index = (y / 2) * (width / 2) + x / 2;
      writeSample(output, cbOffset + index, chroma.cb, bytesPerSample);
      writeSample(output, crOffset + index, chroma.cr, bytesPerSample);
    }
  }

  return output;
}

function validateInput(
  rgba: Uint16Array,
  input: Readonly<Rgba16ToYuv420Input>
): Readonly<Rgba16ToYuv420Input> {
  if (typeof input !== "object" || input === null) {
    throw invalid("YUV420 conversion input must be an object");
  }
  const { width, height, bitDepth } = input;
  if (
    !Number.isSafeInteger(width) ||
    !Number.isSafeInteger(height) ||
    width < 2 ||
    height < 2
  ) {
    throw invalid("YUV420 dimensions must be positive safe integers of at least two");
  }
  if (width % 2 !== 0 || height % 2 !== 0) {
    throw invalid("YUV420 dimensions must be even");
  }
  if (bitDepth !== 8 && bitDepth !== 10) {
    throw invalid("YUV420 bit depth must be 8 or 10");
  }
  if (!(rgba instanceof Uint16Array)) {
    throw invalid("YUV420 conversion requires canonical RGBA16 channels");
  }
  const expectedLength = checkedProduct(width, height, RGBA_CHANNELS);
  if (rgba.length !== expectedLength) {
    throw invalid("RGBA16 length does not match the YUV420 frame geometry");
  }
  return Object.freeze({ width, height, bitDepth });
}

function luma(red: number, green: number, blue: number, bitDepth: 8 | 10): number {
  const minimum = bitDepth === 10 ? 64 : 16;
  const maximum = bitDepth === 10 ? 940 : 235;
  const range = maximum - minimum;
  return clamp(minimum, maximum, minimum + roundSignedRatio(
    range * weightedLuma(red, green, blue),
    UINT16_MAXIMUM * LUMA_SCALE
  ));
}

function chromaSamples(
  blueDifference: number,
  redDifference: number,
  bitDepth: 8 | 10
): { readonly cb: number; readonly cr: number } {
  const minimum = bitDepth === 10 ? 64 : 16;
  const maximum = bitDepth === 10 ? 960 : 240;
  const midpoint = bitDepth === 10 ? 512 : 128;
  const range = bitDepth === 10 ? 896 : 224;
  const cb = clamp(minimum, maximum, midpoint + roundSignedRatio(
    range * blueDifference,
    4 * UINT16_MAXIMUM * 18_556
  ));
  const cr = clamp(minimum, maximum, midpoint + roundSignedRatio(
    range * redDifference,
    4 * UINT16_MAXIMUM * 15_748
  ));
  return Object.freeze({ cb, cr });
}

function weightedLuma(red: number, green: number, blue: number): number {
  return LUMA_RED * red + LUMA_GREEN * green + LUMA_BLUE * blue;
}

function writeSample(
  output: Uint8Array,
  sampleIndex: number,
  value: number,
  bytesPerSample: 1 | 2
): void {
  if (bytesPerSample === 1) {
    output[sampleIndex] = value;
    return;
  }
  const offset = sampleIndex * 2;
  output[offset] = value & 0xff;
  output[offset + 1] = value >>> 8;
}

function checkedProduct(...values: number[]): number {
  let result = 1;
  for (const value of values) {
    result *= value;
    if (!Number.isSafeInteger(result) || result < 0) {
      throw invalid("YUV420 buffer size exceeds the safe integer range");
    }
  }
  return result;
}

function clamp(minimum: number, maximum: number, value: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

function invalid(message: string): CompilerError {
  return new CompilerError("INPUT_INVALID", message, { phase: "pixel-pipeline" });
}
