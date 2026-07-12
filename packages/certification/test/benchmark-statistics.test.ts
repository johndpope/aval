import { describe, expect, it } from "vitest";
import { summarizeBenchmark } from "../src/benchmark-statistics.js";

describe("benchmark statistics", () => {
  it("uses deterministic nearest-rank statistics over raw finite samples", () => {
    expect(summarizeBenchmark({ clock: "performance-time-origin", unit: "microseconds", warmupCount: 10, samples: [5, 1, 3, 4, 2] })).toEqual({
      count: 5,
      minimum: 1,
      maximum: 5,
      median: 3,
      p95: 5,
      p99: 5
    });
  });

  it("rejects missing samples and non-finite data", () => {
    expect(() => summarizeBenchmark({ clock: "clock", unit: "ms", warmupCount: 0, samples: [] })).toThrow(/at least/u);
    expect(() => summarizeBenchmark({ clock: "clock", unit: "ms", warmupCount: 0, samples: [Number.NaN] })).toThrow(/finite/u);
  });
});
