import type { CertificationStatus } from "./status.js";

export type OwnershipCounters = Readonly<Record<string, number>>;

export interface OwnershipCriteriaResult {
  readonly status: CertificationStatus;
  readonly deltas: Readonly<Record<string, number>>;
  readonly peakRegressions: readonly string[];
}

export function evaluateOwnershipSettlement(
  baseline: OwnershipCounters,
  peak: OwnershipCounters,
  terminal: OwnershipCounters,
  limits: OwnershipCounters = Object.freeze({})
): OwnershipCriteriaResult {
  const keys = new Set([...Object.keys(baseline), ...Object.keys(peak), ...Object.keys(terminal), ...Object.keys(limits)]);
  const deltas: Record<string, number> = Object.create(null) as Record<string, number>;
  const peakRegressions: string[] = keys.size === 0 ? ["ownership-counters-empty"] : [];
  for (const key of [...keys].sort()) {
    const base = counter(baseline[key] ?? 0, `baseline.${key}`);
    const peakValue = counter(peak[key] ?? 0, `peak.${key}`);
    const final = counter(terminal[key] ?? 0, `terminal.${key}`);
    if (peakValue < base || peakValue < final) throw new RangeError(`peak.${key} must cover baseline and terminal`);
    deltas[key] = final - base;
    const limit = limits[key];
    if (limit !== undefined && peakValue > counter(limit, `limits.${key}`)) peakRegressions.push(`${key}:${peakValue}>${limit}`);
  }
  const settled = Object.values(deltas).every((delta) => delta === 0);
  return {
    status: keys.size === 0 ? "inconclusive" : settled && peakRegressions.length === 0 ? "passed" : "failed",
    deltas,
    peakRegressions
  };
}

function counter(value: number, path: string): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`${path} must be a nonnegative safe integer`);
  return value;
}
