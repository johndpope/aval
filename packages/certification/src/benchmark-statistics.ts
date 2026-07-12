export interface BenchmarkStatistics {
  readonly count: number;
  readonly minimum: number;
  readonly maximum: number;
  readonly median: number;
  readonly p95: number;
  readonly p99: number;
}

export interface BenchmarkSampleSet {
  readonly clock: string;
  readonly unit: string;
  readonly warmupCount: number;
  readonly samples: readonly number[];
}

export function summarizeBenchmark(input: BenchmarkSampleSet, minimumSamples = 1): BenchmarkStatistics {
  if (input.clock.length === 0 || input.unit.length === 0) throw new TypeError("clock and unit are required");
  if (!Number.isSafeInteger(input.warmupCount) || input.warmupCount < 0) throw new RangeError("warmupCount must be a nonnegative safe integer");
  if (!Number.isSafeInteger(minimumSamples) || minimumSamples < 1) throw new RangeError("minimumSamples must be positive");
  if (input.samples.length < minimumSamples) throw new RangeError(`at least ${minimumSamples} measured samples are required`);
  const samples = [...input.samples];
  for (const sample of samples) if (!Number.isFinite(sample)) throw new RangeError("benchmark samples must be finite");
  samples.sort((left, right) => left - right);
  return {
    count: samples.length,
    minimum: samples[0] ?? 0,
    maximum: samples.at(-1) ?? 0,
    median: nearestRank(samples, 50),
    p95: nearestRank(samples, 95),
    p99: nearestRank(samples, 99)
  };
}

function nearestRank(sorted: readonly number[], percentile: number): number {
  const rank = Math.max(1, Math.ceil(sorted.length * percentile / 100));
  return sorted[rank - 1] ?? 0;
}
