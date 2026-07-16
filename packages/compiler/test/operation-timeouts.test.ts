import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deriveVideoRenditionGeometry } from "@pixel-point/aval-format";

import { compileDirectInput } from "../src/compile/project-compiler.js";
import { compileProjectFile } from "../src/compile/project-compiler.js";
import { encodeElementaryVideoUnit } from "../src/ffmpeg/video-encode-unit.js";
import { probeMedia } from "../src/ffmpeg/probe.js";

describe("configurable operation timeouts", () => {
  let directory = "";
  let hangingTool = "";
  let yuvPath = "";

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "aval-timeout-tool-"));
    hangingTool = join(directory, "hang");
    yuvPath = join(directory, "frame.yuv");
    await writeFile(
      hangingTool,
      "#!/usr/bin/env node\nsetInterval(() => {}, 1000);\n",
      { mode: 0o700 }
    );
    await chmod(hangingTool, 0o700);
    await writeFile(yuvPath, new Uint8Array(32 * 32 * 3 / 2));
  });

  afterAll(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  it("lowers the 15-second probe default", async () => {
    await expect(probeMedia(
      "/input/clip.mov",
      hangingTool,
      undefined,
      20
    )).rejects.toMatchObject({ code: "PROCESS_TIMEOUT" });
  });

  it("enforces an explicitly configured media timeout", async () => {
    const rendition = {
      id: "video.main",
      width: 32,
      height: 32,
      crf: 20
    } as const;
    const geometry = deriveVideoRenditionGeometry({
      canvasWidth: 32,
      canvasHeight: 32,
      layout: "opaque",
      visibleWidth: 32,
      visibleHeight: 32,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    });
    await expect(encodeElementaryVideoUnit({
      source: {
        path: yuvPath,
        width: 32,
        height: 32,
        bitDepth: 8,
        frameRate: { numerator: 30, denominator: 1 },
        frameBytes: 1_536
      },
      startFrame: 0,
      endFrame: 1,
      encoding: {
        codec: "h264",
        preset: "medium",
        renditions: [rendition]
      },
      rendition,
      geometry,
      executable: hangingTool,
      timeoutMs: 20
    })).rejects.toMatchObject({ code: "PROCESS_TIMEOUT" });
  });

  it("threads positive timeout validation through both public compiler entries", async () => {
    await expect(compileDirectInput({
      inputPath: "/input/never-opened.mov",
      outputPath: "/output/never-written",
      loop: [0, 1],
      codec: "h264",
      probeTimeoutMs: 0,
      mediaTimeoutMs: 20
    })).rejects.toMatchObject({
      code: "INPUT_INVALID",
      message: expect.stringContaining("Probe timeout")
    });

    await expect(compileProjectFile({
      projectPath: "/input/never-opened.json",
      outputPath: "/output/never-written",
      probeTimeoutMs: 20,
      mediaTimeoutMs: 0
    })).rejects.toMatchObject({
      code: "INPUT_INVALID",
      message: expect.stringContaining("Media timeout")
    });
  });
});
