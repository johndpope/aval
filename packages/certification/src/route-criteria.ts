import type { CertificationStatus } from "./status.js";

export interface RouteLedgerEntry {
  readonly requestOrdinal: number;
  readonly kind: "portal" | "finish" | "cut" | "locked" | "reversal";
  readonly selectedWaitFrames: number;
  readonly maximumWaitFrames: number;
  readonly requiredFirstContentOrdinal: number;
  readonly actualFirstContentOrdinal: number | null;
  readonly requestContentOrdinal: number;
  readonly newestAcceptedSequence: number;
  readonly settledSequence: number;
}

export interface RouteCriteriaResult {
  readonly status: CertificationStatus;
  readonly firstFailingRequestOrdinal: number | null;
  readonly failures: readonly string[];
}

export function evaluateRouteCriteria(entries: readonly RouteLedgerEntry[]): RouteCriteriaResult {
  const failures: string[] = entries.length === 0 ? ["route-ledger-empty"] : [];
  let firstFailingRequestOrdinal: number | null = null;
  const ordinals = new Set<number>();
  for (const entry of entries) {
    for (const [field, value] of Object.entries(entry)) {
      if (field === "kind" || value === null) continue;
      if (!Number.isSafeInteger(value) || (value as number) < 0) throw new RangeError(`${field} must be a nonnegative safe integer`);
    }
    const current: string[] = [];
    if (ordinals.has(entry.requestOrdinal)) current.push("duplicate-request-ordinal");
    ordinals.add(entry.requestOrdinal);
    if (entry.selectedWaitFrames > entry.maximumWaitFrames) current.push("route-wait-exceeded");
    if (entry.actualFirstContentOrdinal !== entry.requiredFirstContentOrdinal) current.push("wrong-route-entry-content");
    if (entry.kind === "reversal" && entry.requiredFirstContentOrdinal !== entry.requestContentOrdinal + 1) current.push("reversal-not-adjacent-next-frame");
    if (entry.settledSequence !== entry.newestAcceptedSequence) current.push("latest-wins-divergence");
    if (current.length > 0 && firstFailingRequestOrdinal === null) firstFailingRequestOrdinal = entry.requestOrdinal;
    failures.push(...current.map((failure) => `${failure}:${entry.requestOrdinal}`));
  }
  return {
    status: entries.length === 0 ? "inconclusive" : failures.length === 0 ? "passed" : "failed",
    firstFailingRequestOrdinal,
    failures
  };
}
