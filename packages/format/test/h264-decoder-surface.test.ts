import { describe, expect, it } from "vitest";

import {
  maximumH264DecodedRgbaBytes,
  maximumH264DecoderSurfaceDimension
} from "../src/h264/index.js";

describe("H264 decoder surface reserve", () => {
  it("reserves two padded macroblocks beyond aligned coded geometry", () => {
    expect(maximumH264DecoderSurfaceDimension(32)).toBe(64);
    expect(maximumH264DecoderSurfaceDimension(33)).toBe(80);
    expect(maximumH264DecodedRgbaBytes(32, 32)).toBe(64 * 64 * 4);
  });

  it("accepts larger representable dimensions and rejects unsafe arithmetic", () => {
    expect(() => maximumH264DecoderSurfaceDimension(0)).toThrow();
    expect(maximumH264DecoderSurfaceDimension(2_049)).toBe(2_096);
    expect(() => maximumH264DecoderSurfaceDimension(Number.MAX_SAFE_INTEGER))
      .toThrow(/safe-integer/u);
  });
});
