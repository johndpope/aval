import { describe, expect, it } from "vitest";

import { computeIntrinsicSize } from "../src/intrinsic-size.js";

describe("intrinsic size", () => {
  it("derives display geometry from logical canvas and pixel aspect", () => {
    expect(computeIntrinsicSize({
      width: 15,
      height: 9,
      pixelAspect: [4, 3]
    })).toEqual({ width: 20, height: 9, aspectRatio: 20 / 9 });
  });

  it("rejects non-positive or fractional manifest geometry", () => {
    expect(() => computeIntrinsicSize({
      width: 0,
      height: 9,
      pixelAspect: [1, 1]
    })).toThrow();
  });
});
