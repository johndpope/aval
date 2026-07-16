import { describe, expect, it } from "vitest";

import { inspectVp9Rendition } from "../src/vp9/inspector.js";

const KEY = Uint8Array.of(
  0x82, 0x49, 0x83, 0x42, 0x40, 0x03, 0xf0, 0x01, 0xf6, 0x08
);

describe("VP9 rendition inspection", () => {
  it("derives a fully qualified codec and permits hidden frames", () => {
    const marker = 0xc1;
    const hiddenAndShown = Uint8Array.of(0x84, 0x86, marker, 1, 1, marker);
    expect(inspectVp9Rendition({
      width: 64,
      height: 32,
      frameRate: { numerator: 30, denominator: 1 },
      averageBitrate: 100_000,
      units: [{
        id: "idle",
        expectedDisplayedFrames: 2,
        packets: [
          { bytes: KEY, key: true, timestamp: 0 },
          { bytes: hiddenAndShown, key: false, timestamp: 1 }
        ]
      }]
    })).toMatchObject({
      codec: "vp09.00.10.08.01.01.01.01.00",
      width: 64,
      height: 32,
      bitDepth: 8,
      units: [{ displayedFrameCount: 2 }]
    });
  });

  it("rejects a non-key unit start and authored display mismatch", () => {
    const base = {
      width: 64,
      height: 32,
      frameRate: { numerator: 30, denominator: 1 },
      averageBitrate: 100_000
    } as const;
    expect(() => inspectVp9Rendition({
      ...base,
      units: [{
        id: "idle",
        expectedDisplayedFrames: 1,
        packets: [{ bytes: Uint8Array.of(0x86), key: false, timestamp: 0 }]
      }]
    })).toThrow(/start with a key/u);
    expect(() => inspectVp9Rendition({
      ...base,
      units: [{
        id: "idle",
        expectedDisplayedFrames: 2,
        packets: [{ bytes: KEY, key: true, timestamp: 0 }]
      }]
    })).toThrow(/displayed frame count/u);
  });
});
