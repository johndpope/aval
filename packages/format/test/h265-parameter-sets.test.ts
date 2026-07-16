import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import {
  createH265VideoDecoderConfig,
  h265CodecString,
  parseH265Pps,
  parseH265Sps,
  parseH265Vps,
  splitH265AnnexBAccessUnit
} from "../src/h265/index.js";
import {
  makeH265Pps,
  makeH265Sps,
  makeH265Vps
} from "./h265-fixture.js";

describe("HEVC parameter sets and codec configuration", () => {
  it("parses the bounded Main profile and derives an exact hvc1 config", () => {
    const vps = parseOne(makeH265Vps(), 32, parseH265Vps);
    const sps = parseOne(makeH265Sps(), 33, parseH265Sps);
    const pps = parseOne(makeH265Pps(), 34, parseH265Pps);

    expect(vps).toMatchObject({ id: 0, maxSubLayers: 1 });
    expect(sps).toMatchObject({
      id: 0,
      codedWidth: 64,
      codedHeight: 64,
      bitDepthLuma: 8,
      bitDepthChroma: 8,
      maxNumReorderPics: 2,
      maxDecPicBuffering: 5,
      color: {
        fullRange: false,
        colourPrimaries: 1,
        transferCharacteristics: 1,
        matrixCoefficients: 1
      }
    });
    expect(pps).toMatchObject({ id: 0, spsId: 0, entropyCodingSyncEnabled: true });
    expect(h265CodecString(sps.profileTierLevel)).toBe("hvc1.1.6.L30.90");
    expect(createH265VideoDecoderConfig(sps)).toEqual({
      codec: "hvc1.1.6.L30.90",
      codedWidth: 64,
      codedHeight: 64,
      displayAspectWidth: 64,
      displayAspectHeight: 64,
      colorSpace: {
        primaries: "bt709",
        transfer: "bt709",
        matrix: "bt709",
        fullRange: false
      }
    });
  });

  it("serializes profile-space, tier, level, and trimmed constraint bytes", () => {
    const sps = parseOne(
      makeH265Sps({
        ptl: {
          profileSpace: 2,
          tier: true,
          profileIdc: 4,
          compatibilityProfileIndexes: [4, 7],
          constraintBytes: [0x90, 0xab, 0, 0, 0, 0],
          levelIdc: 93
        }
      }),
      33,
      parseH265Sps
    );
    expect(h265CodecString(sps.profileTierLevel)).toBe("hvc1.B4.90.H93.90.AB");
  });

  it.each([
    ["10-bit", { bitDepthMinus8: 2 }],
    ["invalid crop", { crop: [0, 40, 0, 0] as const }],
    ["zero timing", { timeScale: 0 }],
    ["long-term references", { longTermReferences: true }]
  ])("rejects or reports an unsupported SPS: %s", (_label, options) => {
    const parse = () => parseOne(makeH265Sps(options), 33, parseH265Sps);
    if (_label === "long-term references") {
      expect(parse().longTermReferencePicturesPresent).toBe(true);
    } else {
      expect(parse).toThrow(FormatError);
    }
  });

  it("rejects every truncation through mandatory SPS syntax", () => {
    const complete = makeH265Sps();
    for (let length = 0; length < Math.min(complete.length, 28); length += 1) {
      const truncated = complete.slice(0, length);
      expect(
        () => splitH265AnnexBAccessUnit(truncated, "sps").forEach((nal) => {
          if (nal.type === 33) parseH265Sps(nal, "sps");
        }),
        `prefix ${String(length)}`
      ).toThrow(FormatError);
    }
  });
});

function parseOne<T>(
  bytes: Uint8Array,
  expectedType: number,
  parse: (nal: ReturnType<typeof splitH265AnnexBAccessUnit>[number], path: string) => T
): T {
  const nal = splitH265AnnexBAccessUnit(bytes, "parameterSet")[0];
  if (nal === undefined || nal.type !== expectedType) throw new Error("fixture type mismatch");
  return parse(nal, "parameterSet");
}
