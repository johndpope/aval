export interface CertificationFrameLedgerEntry {
  readonly deadlineOrdinal: number;
  readonly contentOrdinal: number;
  readonly requiredContentOrdinal: number;
  readonly eventAvailableBeforeCutoff: boolean;
  readonly framePreparedBeforeCutoff: boolean;
  readonly eligibleAnimationFrameOrdinal: number;
  readonly callbackStartMicroseconds: number;
  readonly canvasSubmissionCompleteMicroseconds: number;
  readonly gpuFence: "not-supported" | "not-used" | "completed" | "failed";
  readonly state: string;
  readonly unit: string;
  readonly localFrame: number;
}

export class CertificationFrameLedger {
  readonly #maximumEntries: number;
  readonly #entries: CertificationFrameLedgerEntry[] = [];

  public constructor(maximumEntries = 100_000) {
    if (!Number.isSafeInteger(maximumEntries) || maximumEntries < 1 || maximumEntries > 2_000_000) throw new RangeError("maximumEntries must be in 1..2000000");
    this.#maximumEntries = maximumEntries;
  }

  public append(entry: CertificationFrameLedgerEntry): void {
    if (this.#entries.length >= this.#maximumEntries) throw new RangeError("frame ledger entry limit exceeded");
    for (const [field, value] of Object.entries(entry)) {
      if (typeof value === "number" && (!Number.isSafeInteger(value) || value < 0)) throw new RangeError(`${field} must be a nonnegative safe integer`);
    }
    const prior = this.#entries.at(-1);
    if (prior !== undefined) {
      if (entry.deadlineOrdinal <= prior.deadlineOrdinal) throw new RangeError("deadlineOrdinal must increase strictly");
      if (entry.callbackStartMicroseconds < prior.callbackStartMicroseconds) throw new RangeError("callback clock moved backward");
    }
    if (entry.canvasSubmissionCompleteMicroseconds < entry.callbackStartMicroseconds) throw new RangeError("canvas submission precedes callback start");
    if (entry.state.length === 0 || entry.state.length > 128 || entry.unit.length === 0 || entry.unit.length > 128) throw new RangeError("state/unit identifier length is invalid");
    this.#entries.push(Object.freeze({ ...entry }));
  }

  public snapshot(): readonly CertificationFrameLedgerEntry[] {
    return Object.freeze(this.#entries.map((entry) => Object.freeze({ ...entry })));
  }
}
