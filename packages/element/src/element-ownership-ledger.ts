export type ElementOwnershipKind =
  | "listener"
  | "observer"
  | "broker"
  | "timer"
  | "command";

export interface ElementOwnershipSnapshot {
  readonly listenerCount: number;
  readonly observerCount: number;
  readonly brokerSubscriptionCount: number;
  readonly timerCount: number;
  readonly pendingCommandCount: number;
  readonly failedReleaseCount: number;
  readonly retainedRetryCount: number;
  readonly releaseFailureCount: number;
  readonly completed: boolean;
}

interface OwnedRecord {
  readonly kind: ElementOwnershipKind;
  retry: (() => void) | null;
}

export interface ElementOwnershipHandle {
  readonly active: boolean;
  complete(): void;
  release(operation: () => void): boolean;
}

/** Exact, retryable element-side physical ownership accounting. */
export class ElementOwnershipLedger {
  readonly #maximumOwners: number;
  readonly #maximumReleaseFailures: number;
  readonly #maximumOwnerId: number;
  readonly #owners = new Map<number, OwnedRecord>();
  #nextId = 0;
  #releaseFailureCount = 0;

  public constructor(options: Readonly<{
    maximumOwners?: number;
    maximumReleaseFailures?: number;
    maximumOwnerId?: number;
  }> = {}) {
    this.#maximumOwners = options.maximumOwners ?? 256;
    this.#maximumReleaseFailures = options.maximumReleaseFailures ?? 65_535;
    this.#maximumOwnerId = options.maximumOwnerId ?? Number.MAX_SAFE_INTEGER;
    if (!Number.isSafeInteger(this.#maximumOwners) || this.#maximumOwners < 1) {
      throw new RangeError("element ownership maximum is invalid");
    }
    if (
      !Number.isSafeInteger(this.#maximumReleaseFailures) ||
      this.#maximumReleaseFailures < 1
    ) throw new RangeError("element release failure maximum is invalid");
    if (!Number.isSafeInteger(this.#maximumOwnerId) || this.#maximumOwnerId < 1) {
      throw new RangeError("element ownership id maximum is invalid");
    }
  }

  public acquire(kind: ElementOwnershipKind): ElementOwnershipHandle {
    if (this.#owners.size >= this.#maximumOwners) {
      throw new Error("element ownership capacity exceeded");
    }
    if (this.#nextId >= this.#maximumOwnerId) {
      throw new Error("element ownership id sequence is exhausted");
    }
    const id = ++this.#nextId;
    this.#owners.set(id, { kind, retry: null });
    let operation: (() => void) | null = null;
    const ledger = this;
    return Object.freeze({
      get active(): boolean { return ledger.#owners.has(id); },
      complete(): void { ledger.#owners.delete(id); },
      release(nextOperation: () => void): boolean {
        operation ??= nextOperation;
        return ledger.#attempt(id, operation);
      }
    });
  }

  public retryAll(): boolean {
    for (const [id, record] of [...this.#owners]) {
      if (record.retry !== null) this.#attempt(id, record.retry);
    }
    return ![...this.#owners.values()].some(({ retry }) => retry !== null);
  }

  public snapshot(): Readonly<ElementOwnershipSnapshot> {
    const counts: Record<ElementOwnershipKind, number> = {
      listener: 0,
      observer: 0,
      broker: 0,
      timer: 0,
      command: 0
    };
    let retainedRetryCount = 0;
    for (const record of this.#owners.values()) {
      counts[record.kind] += 1;
      if (record.retry !== null) retainedRetryCount += 1;
    }
    return Object.freeze({
      listenerCount: counts.listener,
      observerCount: counts.observer,
      brokerSubscriptionCount: counts.broker,
      timerCount: counts.timer,
      pendingCommandCount: counts.command,
      failedReleaseCount: retainedRetryCount,
      retainedRetryCount,
      releaseFailureCount: this.#releaseFailureCount,
      completed: this.#owners.size === 0
    });
  }

  #attempt(id: number, operation: () => void): boolean {
    const record = this.#owners.get(id);
    if (record === undefined) return true;
    try {
      operation();
      this.#owners.delete(id);
      return true;
    } catch {
      record.retry = operation;
      this.#releaseFailureCount = Math.min(
        this.#maximumReleaseFailures,
        this.#releaseFailureCount + 1
      );
      return false;
    }
  }
}
