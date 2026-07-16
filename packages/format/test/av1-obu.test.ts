import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import { readAv1Leb128 } from "../src/av1/leb128.js";
import { parseAv1LowOverheadObus } from "../src/av1/obu.js";

describe("AV1 low-overhead OBU parsing", () => {
  it("parses temporal delimiter, sequence, and frame OBUs into owned payloads", () => {
    const bytes = Uint8Array.of(0x12, 0x00, 0x0a, 0x02, 0xaa, 0xbb, 0x32, 0x01, 0x14);
    const parsed = parseAv1LowOverheadObus(bytes);
    expect(parsed).toEqual([
      { type: 2, temporalId: 0, spatialId: 0, payload: new Uint8Array() },
      { type: 1, temporalId: 0, spatialId: 0, payload: Uint8Array.of(0xaa, 0xbb) },
      { type: 6, temporalId: 0, spatialId: 0, payload: Uint8Array.of(0x14) }
    ]);
    bytes.fill(0);
    expect(parsed[1]?.payload).toEqual(Uint8Array.of(0xaa, 0xbb));
  });

  it("requires canonical bounded LEB128 and valid OBU headers", () => {
    expect(readAv1Leb128(Uint8Array.of(0x81, 0x01), 0)).toEqual({ value: 129, length: 2 });
    for (const bytes of [
      Uint8Array.of(0x80, 0x00),
      Uint8Array.of(0x80),
      Uint8Array.of(0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80)
    ]) {
      expect(() => readAv1Leb128(bytes, 0)).toThrow(FormatError);
    }
    for (const bytes of [
      Uint8Array.of(0x92, 0x00),
      Uint8Array.of(0x10),
      Uint8Array.of(0x42, 0x00),
      Uint8Array.of(0x12, 0x01, 0x00),
      Uint8Array.of(0x32, 0x02, 0x14)
    ]) {
      expect(() => parseAv1LowOverheadObus(bytes)).toThrow(FormatError);
    }
  });
});
