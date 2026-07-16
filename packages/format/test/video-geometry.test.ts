import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import {
  deriveVideoRenditionGeometry,
  PACKED_ALPHA_GUTTER
} from "../src/video/geometry.js";

describe("deriveVideoRenditionGeometry", () => {
  it("derives opaque geometry using codec-owned storage alignment", () => {
    expect(deriveVideoRenditionGeometry({
      canvasWidth: 15,
      canvasHeight: 17,
      layout: "opaque",
      visibleWidth: 15,
      visibleHeight: 17,
      storage: { widthAlignment: 16, heightAlignment: 16 }
    })).toEqual({
      layout: "opaque",
      visibleColorRect: [0, 0, 15, 17],
      decodedStorageRect: [0, 0, 16, 18],
      codedWidth: 16,
      codedHeight: 32,
      visibleColorArea: 255,
      decodedRgbaBytes: 16 * 18 * 4,
      codedRgbaBytes: 16 * 32 * 4
    });
  });

  it("uses one shared packed-alpha layout for every codec", () => {
    const result = deriveVideoRenditionGeometry({
      canvasWidth: 15,
      canvasHeight: 17,
      layout: "packed-alpha",
      visibleWidth: 15,
      visibleHeight: 17,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    });
    expect(result).toEqual({
      layout: "packed-alpha",
      visibleColorRect: [0, 0, 15, 17],
      visibleAlphaRect: [0, 18 + PACKED_ALPHA_GUTTER, 15, 17],
      decodedStorageRect: [0, 0, 16, 44],
      codedWidth: 16,
      codedHeight: 44,
      visibleColorArea: 255,
      decodedRgbaBytes: 16 * 44 * 4,
      codedRgbaBytes: 16 * 44 * 4
    });
    expect(Object.isFrozen(result)).toBe(true);
  });

  it("rejects aspect drift, canvas overflow, invalid policy, and unsafe products", () => {
    const base = {
      canvasWidth: 16,
      canvasHeight: 9,
      layout: "opaque" as const,
      visibleWidth: 16,
      visibleHeight: 9,
      storage: { widthAlignment: 2, heightAlignment: 2 }
    };
    for (const input of [
      { ...base, visibleWidth: 15 },
      { ...base, visibleWidth: 17 },
      { ...base, storage: { widthAlignment: 0, heightAlignment: 2 } },
      { ...base, canvasWidth: Number.MAX_SAFE_INTEGER }
    ]) {
      expect(() => deriveVideoRenditionGeometry(input)).toThrowError(FormatError);
    }
  });
});
