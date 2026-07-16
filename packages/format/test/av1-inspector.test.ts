import { describe, expect, it } from "vitest";

import { inspectAv1Rendition } from "../src/av1/inspector.js";

const SEQUENCE = Uint8Array.from(Buffer.from("00000002a7ff36be4404040410", "hex"));

function obu(type: number, payload: Uint8Array): Uint8Array {
  return Uint8Array.of(type << 3 | 0x02, payload.byteLength, ...payload);
}

function packet(...parts: readonly Uint8Array[]): Uint8Array {
  const length = parts.reduce((total, part) => total + part.byteLength, 0);
  const output = new Uint8Array(length);
  let cursor = 0;
  for (const part of parts) {
    output.set(part, cursor);
    cursor += part.byteLength;
  }
  return output;
}

describe("AV1 rendition inspection", () => {
  it("derives a fully qualified codec and preserves frame display semantics", () => {
    const key = packet(obu(2, new Uint8Array()), obu(1, SEQUENCE), obu(6, Uint8Array.of(0x14)));
    const hiddenAndShown = packet(
      obu(2, new Uint8Array()),
      obu(6, Uint8Array.of(0x24)),
      obu(6, Uint8Array.of(0x34))
    );
    expect(inspectAv1Rendition({
      width: 64,
      height: 32,
      bitDepth: 8,
      units: [{
        id: "idle",
        expectedDisplayedFrames: 2,
        chunks: [
          { bytes: key, key: true, timestamp: 0 },
          { bytes: hiddenAndShown, key: false, timestamp: 1 }
        ]
      }]
    })).toMatchObject({
      codec: "av01.0.00M.08.0.110.01.01.01.0",
      sequence: { bitDepth: 8, maxWidth: 64, maxHeight: 32 },
      units: [{ displayedFrameCount: 2 }]
    });
  });

  it("rejects units without a shown key start and display mismatches", () => {
    const key = packet(obu(2, new Uint8Array()), obu(1, SEQUENCE), obu(6, Uint8Array.of(0x14)));
    expect(() => inspectAv1Rendition({
      width: 64,
      height: 32,
      bitDepth: 8,
      units: [{
        id: "idle",
        expectedDisplayedFrames: 2,
        chunks: [{ bytes: key, key: true, timestamp: 0 }]
      }]
    })).toThrow(/displayed frame count/u);
  });
});
