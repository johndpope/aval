import { describe, expect, it } from "vitest";
import { renderBenchmarkMarkdown } from "../src/benchmark-report.js";
import { renderRuntimeReportMarkdown } from "../src/runtime-report.js";
import { validRuntimeReport } from "./test-report.js";

describe("generated human-readable reports", () => {
  it("binds runtime Markdown to canonical JSON and preserves the claim boundary", () => {
    const markdown = renderRuntimeReportMarkdown(validRuntimeReport(), "a".repeat(64));
    expect(markdown).toContain("Canonical JSON SHA-256");
    expect(markdown).toContain("not observed-display or physical scan-out evidence");
  });

  it("refuses contaminated benchmark records", () => {
    const record = {
      id: "decoder-throughput", profileId: "profile-a", hidden: false as const,
      devtools: false as const, readback: false as const, powerChanged: false as const,
      measured: { clock: "performance", unit: "frames-per-second", warmupCount: 30, samples: [60, 61, 62] },
      statistics: { count: 3, minimum: 60, maximum: 62, median: 61, p95: 62, p99: 62 }
    };
    expect(renderBenchmarkMarkdown(record)).toContain("Measured samples: 3");
    expect(() => renderBenchmarkMarkdown({ ...record, hidden: true as never })).toThrow(/contaminated/u);
  });
});
