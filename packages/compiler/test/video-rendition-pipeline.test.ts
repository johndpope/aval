import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseFrontIndex } from "@pixel-point/aval-format";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { compileProjectEncoding } from "../src/compile/project-encoding-compiler.js";
import { compileVideoEncodingRenditions } from "../src/compile/video-rendition-pipeline.js";
import type { PreparedProjectSource } from "../src/compile/project-source.js";
import type { NormalizedSourceProject } from "../src/model.js";

const WIDTH = 64;
const HEIGHT = 32;
const FRAMES = 6;
const HAS_VP9 = hasEncoder("libvpx-vp9");

describe.skipIf(!HAS_VP9)("codec-neutral rendition pipeline", () => {
  let directory = "";
  let rgbaPath = "";

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "aval-video-pipeline-"));
    rgbaPath = join(directory, "canonical.rgba");
    const bytes = new Uint8Array(WIDTH * HEIGHT * 8 * FRAMES);
    const view = new DataView(bytes.buffer);
    for (let frame = 0; frame < FRAMES; frame += 1) {
      const start = frame * WIDTH * HEIGHT * 8;
      for (let pixel = 0; pixel < WIDTH * HEIGHT; pixel += 1) {
        const offset = start + pixel * 8;
        view.setUint16(offset, (24 + frame * 24) * 257, true);
        view.setUint16(offset + 2, 64 * 257, true);
        view.setUint16(offset + 4, (192 - frame * 16) * 257, true);
        view.setUint16(offset + 6, 65_535, true);
      }
    }
    await writeFile(rgbaPath, bytes);
  });

  afterAll(async () => {
    if (directory !== "") await rm(directory, { recursive: true, force: true });
  });

  it("scales, packs, encodes, strips IVF, inspects, and assembles VP9", async () => {
    const project = projectFixture();
    const source = preparedSource();
    const encoding = project.encodings[0]!;
    if (encoding.codec !== "vp9") throw new Error("fixture codec changed");
    const compiled = await compileVideoEncodingRenditions({
      project,
      encoding,
      layout: "opaque",
      sources: new Map([[source.id, source]]),
      executable: "ffmpeg",
      timeoutMs: 30_000
    });

    expect(compiled.invocations.map(({ operation }) => operation)).toEqual([
      "vp9:video.main:idle.body:scale-rgba",
      "vp9:video.main:idle.body:encode"
    ]);
    expect(compiled.renditions[0]).toMatchObject({
      id: "video.main",
      bitDepth: 8,
      geometry: { codedWidth: WIDTH, codedHeight: HEIGHT }
    });
    expect(compiled.renditions[0]?.codec).toMatch(/^vp09\.00\./u);
    const artifact = compileProjectEncoding({
      project,
      encoding,
      layout: "opaque",
      renditions: compiled.renditions
    });
    const front = parseFrontIndex(artifact.assetBytes);
    expect(front.manifest).toMatchObject({
      codec: "vp9",
      bitstream: "frame",
      layout: "opaque"
    });
    expect(front.records.reduce(
      (total, chunk) => total + chunk.displayedFrameCount,
      0
    )).toBe(FRAMES);
  }, 40_000);

  function preparedSource(): Readonly<PreparedProjectSource> {
    return {
      id: "render",
      input: {
        type: "raw-rgba64",
        path: rgbaPath,
        width: WIDTH,
        height: HEIGHT,
        frameRate: { numerator: 6, denominator: 1 }
      },
      spoolFrameCount: FRAMES,
      projectFrameToSpoolFrame: new Map(
        Array.from({ length: FRAMES }, (_, frame) => [frame, frame])
      )
    } as unknown as Readonly<PreparedProjectSource>;
  }
});

function projectFixture(): NormalizedSourceProject {
  return {
    projectVersion: "1.0",
    alpha: "opaque",
    canvas: {
      width: WIDTH,
      height: HEIGHT,
      fit: "contain",
      pixelAspect: [1, 1],
      colorSpace: "srgb"
    },
    frameRate: { numerator: 6, denominator: 1 },
    sources: [{
      id: "render",
      type: "video",
      path: "render.mov",
      timing: { mode: "exact" }
    }],
    encodings: [{
      codec: "vp9",
      deadline: "good",
      cpuUsed: 8,
      threads: 2,
      renditions: [{ id: "video.main", width: WIDTH, height: HEIGHT, crf: 40 }]
    }],
    units: [{
      id: "idle.body",
      kind: "body",
      source: "render",
      range: [0, FRAMES],
      playback: "loop",
      ports: []
    }],
    initialState: "idle",
    states: [{ id: "idle", bodyUnit: "idle.body" }],
    edges: [],
    bindings: []
  };
}

function hasEncoder(name: string): boolean {
  const result = spawnSync("ffmpeg", ["-hide_banner", "-encoders"], {
    encoding: "utf8",
    timeout: 10_000
  });
  return result.status === 0 && result.stdout.includes(name);
}
