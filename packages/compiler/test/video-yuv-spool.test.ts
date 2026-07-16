import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { deriveVideoRenditionGeometry } from "@pixel-point/aval-format";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { writeVideoYuvUnitSpool } from "../src/compile/video-yuv-spool.js";

describe("codec-neutral YUV unit spool", () => {
  let root = "";

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "aval-video-yuv-test-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("writes exact yuv420p bytes and owns cleanup", async () => {
    const geometry = deriveVideoRenditionGeometry({
      canvasWidth: 2,
      canvasHeight: 2,
      layout: "opaque",
      visibleWidth: 2,
      visibleHeight: 2,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    });
    const frame = new Uint16Array(2 * 2 * 4);
    for (let offset = 3; offset < frame.length; offset += 4) frame[offset] = 65_535;
    const spool = await writeVideoYuvUnitSpool({
      geometry,
      frameRate: { numerator: 30, denominator: 1 },
      bitDepth: 8,
      frames: [frame, frame],
      temporaryRoot: root
    });

    expect(spool.source).toMatchObject({
      width: 2,
      height: 2,
      bitDepth: 8,
      frameBytes: 6
    });
    expect(new Uint8Array(await readFile(spool.source.path))).toEqual(
      Uint8Array.of(16, 16, 16, 16, 128, 128, 16, 16, 16, 16, 128, 128)
    );
    await spool.cleanup();
    await expect(stat(spool.source.path)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("writes little-endian yuv420p10le without downconverting RGBA16", async () => {
    const geometry = deriveVideoRenditionGeometry({
      canvasWidth: 2,
      canvasHeight: 2,
      layout: "opaque",
      visibleWidth: 2,
      visibleHeight: 2,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    });
    const frame = new Uint16Array(2 * 2 * 4).fill(65_535);
    const spool = await writeVideoYuvUnitSpool({
      geometry,
      frameRate: { numerator: 24, denominator: 1 },
      bitDepth: 10,
      frames: [frame],
      temporaryRoot: root
    });

    expect(spool.source.frameBytes).toBe(12);
    expect([...new Uint8Array(await readFile(spool.source.path))]).toEqual([
      0xac, 0x03, 0xac, 0x03, 0xac, 0x03, 0xac, 0x03,
      0x00, 0x02, 0x00, 0x02
    ]);
    await spool.cleanup();
  });

  it("rejects frame cardinality and bit depth before publication", async () => {
    const geometry = deriveVideoRenditionGeometry({
      canvasWidth: 2,
      canvasHeight: 2,
      layout: "opaque",
      visibleWidth: 2,
      visibleHeight: 2,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    });
    await expect(writeVideoYuvUnitSpool({
      geometry,
      frameRate: { numerator: 24, denominator: 1 },
      bitDepth: 8,
      frames: [new Uint16Array(3)],
      temporaryRoot: root
    })).rejects.toThrow(/length/u);
  });
});
