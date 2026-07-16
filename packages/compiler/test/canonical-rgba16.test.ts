import { describe, expect, it } from "vitest";

import {
  decodeRgba64Le,
  downconvertRgba16ToRgba8,
  encodeRgba64Le,
  expandRgba8ToRgba16
} from "../src/compile/canonical-rgba16.js";

describe("canonical RGBA16", () => {
  it("expands every 8-bit channel exactly and round-trips it", () => {
    const rgba8 = Uint8Array.of(0, 1, 128, 255, 17, 34, 51, 68);
    const rgba16 = expandRgba8ToRgba16(rgba8);

    expect([...rgba16]).toEqual([
      0, 257, 32_896, 65_535,
      4_369, 8_738, 13_107, 17_476
    ]);
    expect(downconvertRgba16ToRgba8(rgba16)).toEqual(rgba8);
  });

  it("decodes and encodes explicit little-endian rgba64 without host-endian assumptions", () => {
    const bytes = Uint8Array.of(
      0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde
    );
    const channels = decodeRgba64Le(bytes);

    expect([...channels]).toEqual([0x1234, 0x5678, 0x9abc, 0xdef0]);
    expect(encodeRgba64Le(channels)).toEqual(bytes);
  });

  it("preserves source values that are not representable in eight bits", () => {
    const source = Uint16Array.of(1, 257, 1_023, 65_534);
    expect([...decodeRgba64Le(encodeRgba64Le(source))]).toEqual([...source]);
  });

  it("rejects malformed channel and byte cardinality", () => {
    expect(() => expandRgba8ToRgba16(Uint8Array.of(1, 2, 3)))
      .toThrow(/RGBA8/u);
    expect(() => decodeRgba64Le(Uint8Array.of(1, 2)))
      .toThrow(/RGBA64LE/u);
    expect(() => encodeRgba64Le(Uint16Array.of(1, 2, 3)))
      .toThrow(/RGBA16/u);
  });
});
