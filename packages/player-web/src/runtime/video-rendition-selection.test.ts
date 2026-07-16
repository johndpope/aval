import type {
  ProductionRendition,
  VideoCodec,
  VideoLayout
} from "@pixel-point/aval-format";
import { describe, expect, it, vi } from "vitest";

import {
  createVideoRenditionCandidates,
  selectVideoRendition,
  type VideoRenditionSelectionManifest
} from "./video-rendition-selection.js";

const CODECS = Object.freeze({
  h264: Object.freeze({
    codec: "avc1.640020",
    bitstream: "annex-b" as const,
    bitDepth: 8 as const
  }),
  h265: Object.freeze({
    codec: "hvc1.1.6.L30.90",
    bitstream: "annex-b" as const,
    bitDepth: 8 as const
  }),
  vp9: Object.freeze({
    codec: "vp09.00.10.08.01.01.01.01.00",
    bitstream: "frame" as const,
    bitDepth: 8 as const
  }),
  av1: Object.freeze({
    codec: "av01.0.00M.10.0.110.01.01.01.0",
    bitstream: "low-overhead" as const,
    bitDepth: 10 as const
  })
});

describe("wire-1.0 video rendition selection", () => {
  it.each(["h264", "h265", "vp9", "av1"] as const)(
    "probes an exact byte-free %s decoder configuration",
    async (family) => {
      const spec = CODECS[family];
      const manifest = createManifest({ family });
      const probe = vi.fn(async () => true);

      const result = await selectVideoRendition({
        manifest,
        isResourceEligible: () => true,
        probeDecoderConfig: probe
      });

      expect(result.outcome).toBe("selected");
      if (result.outcome !== "selected") throw new Error("fixture was unsupported");
      expect(result.selected).toMatchObject({
        authoredIndex: 0,
        rendition: {
          id: "main",
          codec: spec.codec,
          bitDepth: spec.bitDepth
        },
        decoderConfig: {
          codec: spec.codec,
          codedWidth: 64,
          codedHeight: 32,
          displayAspectWidth: 64,
          displayAspectHeight: 32,
          colorSpace: {
            primaries: "bt709",
            transfer: "bt709",
            matrix: "bt709",
            fullRange: false
          }
        },
        decodedStorage: { width: 64, height: 32, rgbaBytes: 8_192 }
      });
      expect(Object.hasOwn(result.selected.decoderConfig, "description")).toBe(false);
      expect(probe).toHaveBeenCalledOnce();
      expect(probe).toHaveBeenCalledWith(
        result.selected.decoderConfig,
        result.selected
      );
      expect(isDeeplyFrozen(result)).toBe(true);
    }
  );

  it("keeps authored order while filtering resource-ineligible renditions", async () => {
    const manifest = createManifest({
      family: "h264",
      width: 96,
      height: 96,
      renditions: [
        createRendition("authored-first", "h264", 32, 32),
        createRendition("authored-second", "h264", 96, 96),
        createRendition("authored-third", "h264", 64, 64)
      ]
    });
    const resourceChecks: string[] = [];
    const probes: string[] = [];

    const result = await selectVideoRendition({
      manifest,
      isResourceEligible: (candidate) => {
        resourceChecks.push(candidate.rendition.id);
        return candidate.rendition.id !== "authored-first";
      },
      probeDecoderConfig: async (_config, candidate) => {
        probes.push(candidate.rendition.id);
        return candidate.rendition.id === "authored-third";
      }
    });

    expect(result.outcome).toBe("selected");
    if (result.outcome !== "selected") throw new Error("fixture was unsupported");
    expect(result.selected.rendition.id).toBe("authored-third");
    expect(resourceChecks).toEqual([
      "authored-first",
      "authored-second",
      "authored-third"
    ]);
    expect(probes).toEqual(["authored-second", "authored-third"]);
    expect(result.attempts).toEqual([
      {
        authoredIndex: 0,
        rendition: "authored-first",
        outcome: "resource-ineligible"
      },
      {
        authoredIndex: 1,
        rendition: "authored-second",
        outcome: "decoder-unsupported"
      },
      {
        authoredIndex: 2,
        rendition: "authored-third",
        outcome: "selected"
      }
    ]);
  });

  it("does not quality-sort an authored ladder", async () => {
    const manifest = createManifest({
      family: "h264",
      width: 64,
      height: 64,
      renditions: [
        createRendition("small-first", "h264", 32, 32),
        createRendition("large-second", "h264", 64, 64)
      ]
    });
    const probe = vi.fn(async () => true);

    const result = await selectVideoRendition({
      manifest,
      isResourceEligible: () => true,
      probeDecoderConfig: probe
    });

    expect(result.outcome).toBe("selected");
    if (result.outcome !== "selected") throw new Error("fixture was unsupported");
    expect(result.selected.rendition.id).toBe("small-first");
    expect(probe).toHaveBeenCalledOnce();
  });

  it("probes sequentially instead of starting later candidates concurrently", async () => {
    const manifest = createManifest({
      family: "vp9",
      renditions: [
        createRendition("first", "vp9", 64, 32),
        createRendition("second", "vp9", 64, 32)
      ]
    });
    let resolveFirst!: (supported: boolean) => void;
    const firstProbe = new Promise<boolean>((resolve) => {
      resolveFirst = resolve;
    });
    const calls: string[] = [];
    const pending = selectVideoRendition({
      manifest,
      isResourceEligible: () => true,
      probeDecoderConfig: async (_config, candidate) => {
        calls.push(candidate.rendition.id);
        return candidate.rendition.id === "first" ? firstProbe : true;
      }
    });

    expect(calls).toEqual(["first"]);
    resolveFirst(false);
    const result = await pending;
    expect(calls).toEqual(["first", "second"]);
    expect(result.outcome).toBe("selected");
    if (result.outcome === "selected") {
      expect(result.selected.rendition.id).toBe("second");
    }
  });

  it("returns a deterministic all-unsupported result", async () => {
    const manifest = createManifest({
      family: "h265",
      renditions: [
        createRendition("too-large", "h265", 64, 32),
        createRendition("not-decoded", "h265", 64, 32)
      ]
    });
    const probe = vi.fn(async () => false);

    const result = await selectVideoRendition({
      manifest,
      isResourceEligible: ({ rendition }) => rendition.id !== "too-large",
      probeDecoderConfig: probe
    });

    expect(result).toEqual({
      outcome: "all-unsupported",
      selected: null,
      attempts: [
        {
          authoredIndex: 0,
          rendition: "too-large",
          outcome: "resource-ineligible"
        },
        {
          authoredIndex: 1,
          rendition: "not-decoded",
          outcome: "decoder-unsupported"
        }
      ]
    });
    expect(probe).toHaveBeenCalledOnce();
    expect(isDeeplyFrozen(result)).toBe(true);
  });

  it("propagates terminal probe failures and never advances", async () => {
    const manifest = createManifest({
      family: "av1",
      renditions: [
        createRendition("first", "av1", 64, 32),
        createRendition("must-not-run", "av1", 64, 32)
      ]
    });
    const terminal = new Error("worker channel failed");
    const probe = vi.fn(async () => {
      throw terminal;
    });

    await expect(selectVideoRendition({
      manifest,
      isResourceEligible: () => true,
      probeDecoderConfig: probe
    })).rejects.toBe(terminal);
    expect(probe).toHaveBeenCalledOnce();
  });

  it("treats malformed probe and resource responses as terminal", async () => {
    const manifest = createManifest({ family: "vp9" });
    await expect(selectVideoRendition({
      manifest,
      isResourceEligible: () => true,
      probeDecoderConfig: (async () => undefined) as unknown as (
        config: Readonly<VideoDecoderConfig>
      ) => Promise<boolean>
    })).rejects.toThrow(/probe must resolve to a boolean/iu);

    const probe = vi.fn(async () => true);
    await expect(selectVideoRendition({
      manifest,
      isResourceEligible: (() => Promise.resolve(true)) as unknown as () => boolean,
      probeDecoderConfig: probe
    })).rejects.toThrow(/predicate must return a boolean/iu);
    expect(probe).not.toHaveBeenCalled();
  });

  it("derives packed-alpha decoded storage rather than coded padding", async () => {
    const packed = createManifest({
      family: "h265",
      layout: "packed-alpha",
      width: 63,
      height: 31,
      renditions: [{
        ...createRendition("packed", "h265", 64, 72),
        alphaLayout: {
          type: "stacked",
          colorRect: [0, 0, 63, 31],
          alphaRect: [0, 40, 63, 31]
        }
      }]
    });

    const result = await selectVideoRendition({
      manifest: packed,
      isResourceEligible: () => true,
      probeDecoderConfig: async () => true
    });

    expect(result.outcome).toBe("selected");
    if (result.outcome !== "selected") throw new Error("fixture was unsupported");
    expect(result.selected.decoderConfig).toEqual({
      codec: CODECS.h265.codec,
      codedWidth: 64,
      codedHeight: 72,
      displayAspectWidth: 64,
      displayAspectHeight: 72,
      colorSpace: {
        primaries: "bt709",
        transfer: "bt709",
        matrix: "bt709",
        fullRange: false
      }
    });
    expect(result.selected.decodedStorage).toEqual({
      width: 64,
      height: 72,
      rgbaBytes: 18_432
    });
  });

  it("validates and detaches the complete ladder before any callback", async () => {
    const valid = createRendition("valid", "h264", 64, 32);
    const malformed = {
      ...createRendition("malformed", "h264", 64, 32),
      codec: CODECS.vp9.codec
    } as ProductionRendition;
    const manifest = createManifest({
      family: "h264",
      renditions: [valid, malformed]
    });
    const resource = vi.fn(() => true);
    const probe = vi.fn(async () => true);

    await expect(selectVideoRendition({
      manifest,
      isResourceEligible: resource,
      probeDecoderConfig: probe
    })).rejects.toThrow(/codec disagrees with the manifest family/iu);
    expect(resource).not.toHaveBeenCalled();
    expect(probe).not.toHaveBeenCalled();

    const mutable = createRendition("detached", "h264", 64, 32) as {
      bitrate: { average: number; peak: number };
    } & ProductionRendition;
    const candidates = createVideoRenditionCandidates(createManifest({
      family: "h264",
      renditions: [mutable]
    }));
    mutable.bitrate.average = 1;
    expect(candidates[0]!.rendition.bitrate.average).toBe(100_000);
    expect(isDeeplyFrozen(candidates)).toBe(true);
  });
});

function createManifest(options: Readonly<{
  readonly family: VideoCodec;
  readonly layout?: VideoLayout;
  readonly width?: number;
  readonly height?: number;
  readonly renditions?: readonly ProductionRendition[];
}>): VideoRenditionSelectionManifest {
  const spec = CODECS[options.family];
  const width = options.width ?? 64;
  const height = options.height ?? 32;
  return {
    formatVersion: "1.0",
    codec: options.family,
    bitstream: spec.bitstream,
    layout: options.layout ?? "opaque",
    canvas: {
      width,
      height,
      fit: "contain",
      pixelAspect: [1, 1],
      colorSpace: "srgb"
    },
    frameRate: { numerator: 30, denominator: 1 },
    renditions: options.renditions ?? [
      createRendition("main", options.family, width, height)
    ]
  };
}

function createRendition(
  id: string,
  family: VideoCodec,
  width: number,
  height: number
): ProductionRendition {
  const spec = CODECS[family];
  return {
    id,
    codec: spec.codec,
    bitDepth: spec.bitDepth,
    codedWidth: width,
    codedHeight: height,
    alphaLayout: { type: "opaque", colorRect: [0, 0, width, height] },
    bitrate: { average: 100_000, peak: 200_000 }
  };
}

function isDeeplyFrozen(value: unknown, seen = new Set<object>()): boolean {
  if (value === null || typeof value !== "object" || seen.has(value)) return true;
  seen.add(value);
  return Object.isFrozen(value) &&
    Object.values(value).every((entry) => isDeeplyFrozen(entry, seen));
}
