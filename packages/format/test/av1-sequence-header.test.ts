import { describe, expect, it } from "vitest";

import { parseAv1SequenceHeader } from "../src/av1/sequence-header.js";

const LIBAOM_64_X_32_8_BIT = Uint8Array.from(
  Buffer.from("00000002a7ff36be4404040410", "hex")
);

describe("AV1 sequence-header parsing", () => {
  it("parses the libaom Main-profile BT.709 sequence header", () => {
    expect(parseAv1SequenceHeader(LIBAOM_64_X_32_8_BIT)).toMatchObject({
      profile: 0,
      level: 0,
      tier: "M",
      bitDepth: 8,
      maxWidth: 64,
      maxHeight: 32,
      monochrome: false,
      subsamplingX: 1,
      subsamplingY: 1,
      colorPrimaries: 1,
      transferCharacteristics: 1,
      matrixCoefficients: 1,
      fullRange: false
    });
  });

  it("rejects truncation and color-description mutation", () => {
    expect(() => parseAv1SequenceHeader(LIBAOM_64_X_32_8_BIT.slice(0, 4)))
      .toThrow(/truncated/u);
    const changed = LIBAOM_64_X_32_8_BIT.slice();
    changed[10] = (changed[10] ?? 0) ^ 0x80;
    expect(() => parseAv1SequenceHeader(changed)).toThrow();
  });
});
