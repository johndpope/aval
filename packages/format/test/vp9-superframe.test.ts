import { describe, expect, it } from "vitest";

import { splitVp9Superframe } from "../src/vp9/superframe.js";

describe("VP9 superframe parsing", () => {
  it("splits hidden and displayed coded frames into owned bytes", () => {
    const marker = 0xc1;
    const packet = Uint8Array.of(0x84, 0xaa, 0x86, 0xbb, 0xcc, marker, 2, 3, marker);
    const frames = splitVp9Superframe(packet);
    expect(frames).toEqual([
      Uint8Array.of(0x84, 0xaa),
      Uint8Array.of(0x86, 0xbb, 0xcc)
    ]);
    packet.fill(0);
    expect(frames[0]).toEqual(Uint8Array.of(0x84, 0xaa));
  });

  it("returns a detached single frame and rejects malformed indexes", () => {
    const packet = Uint8Array.of(0x86, 0x01);
    const frames = splitVp9Superframe(packet);
    packet.fill(0);
    expect(frames).toEqual([Uint8Array.of(0x86, 0x01)]);
    expect(() => splitVp9Superframe(Uint8Array.of(0x84, 0xc1, 1, 1, 0xc1)))
      .toThrow(/sizes/u);
  });
});
