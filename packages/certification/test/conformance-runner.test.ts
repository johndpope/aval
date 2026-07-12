import { describe, expect, it } from "vitest";
import { runConformance } from "../src/conformance-runner.js";

describe("conformance runner", () => {
  it("retains ordered passed, unsupported, and failed cases with normalized failures", async () => {
    let clock = 0;
    const run = await runConformance([
      { id: "format", seed: 1, run: async () => ({ status: "passed", assertions: 10, summary: "strict format passed" }) },
      { id: "production-codec", seed: 2, run: async () => ({ status: "unsupported", assertions: 1, summary: "exact codec unavailable" }) },
      { id: "hostile", seed: 3, run: async () => { throw new Error("private /Users/operator/file"); } }
    ], {
      now: () => clock++,
      wallClock: () => clock === 0 ? "2026-07-12T00:00:00.000Z" : "2026-07-12T00:00:01.000Z"
    });
    expect(run.status).toBe("failed");
    expect(run.cases.map((value) => value.status)).toEqual(["passed", "unsupported", "failed"]);
    expect(run.cases[2]?.summary).toBe("case failed: Error");
  });

  it("rejects duplicates and bounds task count", async () => {
    const task = { id: "same", seed: 1, run: async () => ({ status: "passed" as const, assertions: 1, summary: "ok" }) };
    await expect(runConformance([task, task])).rejects.toThrow(/duplicate/u);
    await expect(runConformance([task], { maximumTasks: 0 })).rejects.toThrow(/maximumTasks/u);
    await expect(runConformance([])).rejects.toThrow(/at least one/u);
  });
});
