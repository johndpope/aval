import { describe, expect, it } from "vitest";

import { addElementCount, nextElementSequence } from "../src/element-sequence.js";

describe("element sequence arithmetic", () => {
  it("fails closed before identities or cumulative public counters lose precision", () => {
    expect(nextElementSequence(4, "test", 5)).toBe(5);
    expect(() => nextElementSequence(5, "test", 5)).toThrow("sequence is exhausted");
    expect(addElementCount(4, 1, "test")).toBe(5);
    expect(() => addElementCount(Number.MAX_SAFE_INTEGER, 1, "test")).toThrow(
      "count is exhausted"
    );
  });
});
