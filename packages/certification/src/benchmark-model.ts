import type { BenchmarkSampleSet, BenchmarkStatistics } from "./benchmark-statistics.js";

export interface BenchmarkRecord {
  readonly id: string;
  readonly profileId: string;
  readonly hidden: false;
  readonly devtools: false;
  readonly readback: false;
  readonly powerChanged: false;
  readonly measured: BenchmarkSampleSet;
  readonly statistics: BenchmarkStatistics;
}
