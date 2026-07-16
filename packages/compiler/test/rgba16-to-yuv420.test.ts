import { describe, expect, it } from "vitest";

import { expandRgba8ToRgba16 } from "../src/compile/canonical-rgba16.js";
import { convertRgba16ToYuv420 } from "../src/compile/rgba16-to-yuv420.js";

function solidRgba16(red: number, green: number, blue: number): Uint16Array {
  return Uint16Array.from(
    Array.from({ length: 4 }, () => [red, green, blue, 65_535]).flat()
  );
}

function words(bytes: Uint8Array): number[] {
  const values: number[] = [];
  for (let offset = 0; offset < bytes.byteLength; offset += 2) {
    values.push(bytes[offset]! | bytes[offset + 1]! << 8);
  }
  return values;
}

describe("RGBA16 to planar YUV420", () => {
  it("maps black and white to exact 8-bit BT.709 limited-range endpoints", () => {
    expect([...convertRgba16ToYuv420(solidRgba16(0, 0, 0), {
      width: 2,
      height: 2,
      bitDepth: 8
    })]).toEqual([16, 16, 16, 16, 128, 128]);

    expect([...convertRgba16ToYuv420(solidRgba16(65_535, 65_535, 65_535), {
      width: 2,
      height: 2,
      bitDepth: 8
    })]).toEqual([235, 235, 235, 235, 128, 128]);
  });

  it("writes 10-bit yuv420p10le samples and preserves sub-8-bit source steps", () => {
    const black = convertRgba16ToYuv420(solidRgba16(0, 0, 0), {
      width: 2,
      height: 2,
      bitDepth: 10
    });
    const white = convertRgba16ToYuv420(solidRgba16(65_535, 65_535, 65_535), {
      width: 2,
      height: 2,
      bitDepth: 10
    });
    expect(words(black)).toEqual([64, 64, 64, 64, 512, 512]);
    expect(words(white)).toEqual([940, 940, 940, 940, 512, 512]);

    const low = solidRgba16(32_768, 32_768, 32_768);
    const high = low.slice();
    for (let offset = 0; offset < high.length; offset += 4) {
      high[offset] = high[offset]! + 128;
      high[offset + 1] = high[offset + 1]! + 128;
      high[offset + 2] = high[offset + 2]! + 128;
    }
    expect(words(convertRgba16ToYuv420(high, {
      width: 2,
      height: 2,
      bitDepth: 10
    }))[0]).toBeGreaterThan(words(convertRgba16ToYuv420(low, {
      width: 2,
      height: 2,
      bitDepth: 10
    }))[0]!);
  });

  it("matches the 8-bit conversion exactly for canonically expanded samples", () => {
    const rgba8 = Uint8Array.of(
      255, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255,
      255, 255, 255, 255
    );
    expect([...convertRgba16ToYuv420(expandRgba8ToRgba16(rgba8), {
      width: 2,
      height: 2,
      bitDepth: 8
    })]).toEqual([63, 173, 32, 235, 128, 128]);
  });

  it("rejects odd geometry and nonexact frame cardinality", () => {
    expect(() => convertRgba16ToYuv420(new Uint16Array(2 * 2 * 4), {
      width: 3,
      height: 2,
      bitDepth: 8
    })).toThrow(/even/u);
    expect(() => convertRgba16ToYuv420(new Uint16Array(3), {
      width: 2,
      height: 2,
      bitDepth: 8
    })).toThrow(/length/u);
  });
});
