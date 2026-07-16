import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deriveVideoRenditionGeometry } from "@pixel-point/aval-format";

import {
  prepareAv1Rendition,
  prepareVp9Rendition
} from "../src/compile/ivf-codec-adapters.js";
import { encodeIvfVideoUnit } from "../src/ffmpeg/video-encode-unit.js";

const WIDTH = 64;
const HEIGHT = 32;
const FRAME_COUNT = 6;
const FRAME_BYTES = WIDTH * HEIGHT * 3 / 2;
const FRAME_BYTES_10 = FRAME_BYTES * 2;
const HAS_CODECS = hasEncoder("libvpx-vp9") && hasEncoder("libaom-av1");
const GEOMETRY = deriveVideoRenditionGeometry({
  canvasWidth: WIDTH,
  canvasHeight: HEIGHT,
  layout: "opaque",
  visibleWidth: WIDTH,
  visibleHeight: HEIGHT,
  storage: { widthAlignment: 2, heightAlignment: 2 }
});

describe.skipIf(!HAS_CODECS)("real IVF codec adapters", () => {
  let directory = "";
  let spool = "";
  let spool10 = "";

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "aval-ivf-codecs-"));
    spool = join(directory, "frames.yuv");
    spool10 = join(directory, "frames-10bit.yuv");
    const bytes = new Uint8Array(FRAME_BYTES * FRAME_COUNT);
    for (let frame = 0; frame < FRAME_COUNT; frame += 1) {
      const start = frame * FRAME_BYTES;
      bytes.fill(32 + frame * 8, start, start + WIDTH * HEIGHT);
      bytes.fill(128, start + WIDTH * HEIGHT, start + FRAME_BYTES);
    }
    await writeFile(spool, bytes);
    const bytes10 = new Uint8Array(FRAME_BYTES_10 * FRAME_COUNT);
    const view = new DataView(bytes10.buffer);
    for (let frame = 0; frame < FRAME_COUNT; frame += 1) {
      const sampleStart = frame * (FRAME_BYTES_10 / 2);
      const lumaSamples = WIDTH * HEIGHT;
      for (let sample = 0; sample < lumaSamples; sample += 1) {
        view.setUint16((sampleStart + sample) * 2, 128 + frame * 32, true);
      }
      for (let sample = lumaSamples; sample < FRAME_BYTES_10 / 2; sample += 1) {
        view.setUint16((sampleStart + sample) * 2, 512, true);
      }
    }
    await writeFile(spool10, bytes10);
  });

  afterAll(async () => {
    if (directory !== "") await rm(directory, { recursive: true, force: true });
  });

  it("strips VP9 IVF and validates the authored display cardinality", async () => {
    const rendition = { id: "tiny", width: WIDTH, height: HEIGHT, crf: 40 };
    const encoded = await encodeIvfVideoUnit({
      source: {
        path: spool,
        width: WIDTH,
        height: HEIGHT,
        bitDepth: 8,
        frameRate: { numerator: 6, denominator: 1 },
        frameBytes: FRAME_BYTES
      },
      startFrame: 0,
      endFrame: FRAME_COUNT,
      encoding: {
        codec: "vp9",
        deadline: "good",
        cpuUsed: 4,
        threads: 2,
        renditions: [rendition]
      },
      rendition,
      geometry: GEOMETRY,
      timeoutMs: 30_000
    });
    const prepared = prepareVp9Rendition({
      width: WIDTH,
      height: HEIGHT,
      frameRate: { numerator: 6, denominator: 1 },
      units: [{
        id: "unit",
        packets: encoded.packets,
        expectedDisplayedFrames: FRAME_COUNT,
      }]
    });

    expect(encoded.timeBase).toEqual({ numerator: 1, denominator: 6 });
    expect(prepared.units[0]?.frameCount).toBe(FRAME_COUNT);
    expect(prepared.codec).toMatch(/^vp09\.00\./u);
  });

  it("strips AV1 IVF and validates explicit BT.709 low-overhead OBUs", async () => {
    const rendition = { id: "tiny", width: WIDTH, height: HEIGHT, crf: 40 };
    const encoded = await encodeIvfVideoUnit({
      source: {
        path: spool,
        width: WIDTH,
        height: HEIGHT,
        bitDepth: 8,
        frameRate: { numerator: 6, denominator: 1 },
        frameBytes: FRAME_BYTES
      },
      startFrame: 0,
      endFrame: FRAME_COUNT,
      encoding: {
        codec: "av1",
        bitDepth: 8,
        cpuUsed: 8,
        tiles: { columns: 1, rows: 1 },
        rowMt: true,
        threads: 2,
        renditions: [rendition]
      },
      rendition,
      geometry: GEOMETRY,
      timeoutMs: 30_000
    });
    const prepared = prepareAv1Rendition({
      width: WIDTH,
      height: HEIGHT,
      bitDepth: 8,
      frameRate: { numerator: 6, denominator: 1 },
      units: [{
        id: "unit",
        packets: encoded.packets,
        expectedDisplayedFrames: FRAME_COUNT
      }]
    });

    expect(encoded.timeBase).toEqual({ numerator: 1, denominator: 6 });
    expect(prepared.units[0]?.frameCount).toBe(FRAME_COUNT);
    expect(prepared.codec).toBe("av01.0.00M.08.0.110.01.01.01.0");
  });

  it("encodes and inspects Main-profile 10-bit AV1", async () => {
    const rendition = { id: "tiny-10", width: WIDTH, height: HEIGHT, crf: 30 };
    const encoded = await encodeIvfVideoUnit({
      source: {
        path: spool10,
        width: WIDTH,
        height: HEIGHT,
        bitDepth: 10,
        frameRate: { numerator: 6, denominator: 1 },
        frameBytes: FRAME_BYTES_10
      },
      startFrame: 0,
      endFrame: FRAME_COUNT,
      encoding: {
        codec: "av1",
        bitDepth: 10,
        cpuUsed: 8,
        tiles: { columns: 1, rows: 1 },
        rowMt: true,
        threads: 2,
        renditions: [rendition]
      },
      rendition,
      geometry: GEOMETRY,
      timeoutMs: 30_000
    });
    const prepared = prepareAv1Rendition({
      width: WIDTH,
      height: HEIGHT,
      bitDepth: 10,
      frameRate: { numerator: 6, denominator: 1 },
      units: [{
        id: "unit",
        packets: encoded.packets,
        expectedDisplayedFrames: FRAME_COUNT
      }]
    });

    expect(prepared.inspection.sequence.bitDepth).toBe(10);
    expect(prepared.codec).toBe("av01.0.00M.10.0.110.01.01.01.0");
  });
});

function hasEncoder(name: string): boolean {
  const result = spawnSync("ffmpeg", ["-hide_banner", "-encoders"], {
    encoding: "utf8",
    timeout: 10_000
  });
  return result.status === 0 && result.stdout.includes(name);
}
