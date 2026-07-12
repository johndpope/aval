import type { BenchmarkRecord } from "./benchmark-model.js";

export function renderBenchmarkMarkdown(record: BenchmarkRecord): string {
  if (record.hidden || record.devtools || record.readback || record.powerChanged) throw new Error("contaminated benchmark cannot be rendered as a measured result");
  return [
    `# Benchmark: ${record.id}`,
    "",
    `Profile: \`${record.profileId}\``,
    `Clock: \`${record.measured.clock}\``,
    `Unit: \`${record.measured.unit}\``,
    `Warm-up samples excluded: ${record.measured.warmupCount}`,
    `Measured samples: ${record.statistics.count}`,
    "",
    `Median: ${record.statistics.median}`,
    `p95: ${record.statistics.p95}`,
    `p99: ${record.statistics.p99}`,
    "",
    "Shared-CI comparisons are advisory unless the named-profile certification policy states an exact normative gate.",
    ""
  ].join("\n");
}
