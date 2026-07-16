import { describe, expect, it } from "vitest";

import {
  isVideoCodecString,
  parseVideoCodecString
} from "../src/video/codec-string.js";

describe("canonical WebCodecs codec strings", () => {
  it("recognizes every production codec family", () => {
    expect(parseVideoCodecString("avc1.640020")).toEqual({ family: "h264" });
    expect(parseVideoCodecString("hvc1.1.6.L93.B0")).toEqual({ family: "h265" });
    expect(parseVideoCodecString("vp09.00.10.08.01.01.01.01.00"))
      .toEqual({ family: "vp9", bitDepth: 8 });
    expect(parseVideoCodecString("av01.0.08M.10.0.110.01.01.01.0"))
      .toEqual({ family: "av1", bitDepth: 10 });
  });

  it("requires family and declared bit depth to agree", () => {
    expect(isVideoCodecString("av01.0.08M.10.0.110.01.01.01.0", "av1", 10))
      .toBe(true);
    expect(isVideoCodecString("av01.0.08M.10.0.110.01.01.01.0", "av1", 8))
      .toBe(false);
    expect(isVideoCodecString("vp09.00.10.08", "av1", 8)).toBe(false);
  });

  it("rejects aliases, truncated forms, lowercase hex, and junk", () => {
    for (const value of [
      "avc1.42e020",
      "hev1.1.6.L93.B0",
      "vp9",
      "av01.0.08M",
      "av01.0.08M.10.0.110.01.01.01.0.extra",
      ""
    ]) {
      expect(parseVideoCodecString(value)).toBeUndefined();
    }
  });
});
