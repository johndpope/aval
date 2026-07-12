export interface DeadlineSample {
  readonly deadlineOrdinal: number;
  readonly eligibleAnimationFrameOrdinal: number;
  readonly eventAvailableMicroseconds: number | null;
  readonly framePreparedMicroseconds: number | null;
  readonly eligibleDeadlineMicroseconds: number;
  readonly callbackStartMicroseconds: number;
  readonly canvasSubmissionCompleteMicroseconds: number;
}

export class DeadlineLedger {
  readonly #limit: number;
  readonly #samples: DeadlineSample[] = [];

  public constructor(limit = 100_000) {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 2_000_000) throw new RangeError("deadline ledger limit is invalid");
    this.#limit = limit;
  }

  public append(input: DeadlineSample): void {
    if (this.#samples.length >= this.#limit) throw new RangeError("deadline ledger limit exceeded");
    const values = Object.entries(input).filter((entry): entry is [string, number] => entry[1] !== null);
    for (const [name, value] of values) {
      if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`${name} must be a nonnegative integer number of microseconds or an ordinal`);
    }
    const previous = this.#samples.at(-1);
    if (previous !== undefined && input.deadlineOrdinal <= previous.deadlineOrdinal) throw new RangeError("deadline ordinals must increase strictly");
    if (input.callbackStartMicroseconds < input.eligibleDeadlineMicroseconds) throw new RangeError("callback starts before its eligible deadline");
    if (input.canvasSubmissionCompleteMicroseconds < input.callbackStartMicroseconds) throw new RangeError("submission completes before callback start");
    this.#samples.push(Object.freeze({ ...input }));
  }

  public snapshot(): readonly Readonly<DeadlineSample>[] {
    return Object.freeze(this.#samples.map((sample) => Object.freeze({ ...sample })));
  }
}
