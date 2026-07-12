import type {
  ElementOwnershipHandle,
  ElementOwnershipLedger
} from "./element-ownership-ledger.js";

interface PendingSnapshot<Snapshot> {
  readonly snapshot: Snapshot;
  readonly resolve: () => void;
  readonly reject: (error: unknown) => void;
  readonly ownership: ElementOwnershipHandle | null;
}

export interface ElementReconcileLaneSnapshot {
  readonly active: number;
  readonly pending: number;
  readonly disposed: boolean;
}

/** One active reconcile plus only the newest pending desired snapshot. */
export class ElementReconcileLane<Snapshot> {
  readonly #apply: (snapshot: Snapshot) => void | PromiseLike<void>;
  readonly #ledger: ElementOwnershipLedger | null;
  #active = false;
  #activeEntry: PendingSnapshot<Snapshot> | null = null;
  #pending: PendingSnapshot<Snapshot> | null = null;
  #disposed = false;
  #idlePromise: Promise<void> | null = null;
  #resolveIdle: (() => void) | null = null;

  public constructor(
    apply: (snapshot: Snapshot) => void | PromiseLike<void>,
    ledger: ElementOwnershipLedger | null = null
  ) {
    this.#apply = apply;
    this.#ledger = ledger;
  }

  public submit(snapshot: Snapshot): Promise<void> {
    if (this.#disposed) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const previous = this.#pending;
      let ownership = previous?.ownership ?? null;
      if (previous === null) ownership = this.#ledger?.acquire("command") ?? null;
      this.#pending = {
        snapshot,
        resolve,
        reject,
        ownership
      };
      previous?.resolve();
      this.#drain();
    });
  }

  public settled(): Promise<void> {
    if (!this.#active && this.#pending === null) return Promise.resolve();
    if (this.#idlePromise === null) {
      this.#idlePromise = new Promise((resolve) => { this.#resolveIdle = resolve; });
    }
    return this.#idlePromise;
  }

  public snapshot(): Readonly<ElementReconcileLaneSnapshot> {
    return Object.freeze({
      active: this.#active ? 1 : 0,
      pending: this.#pending === null ? 0 : 1,
      disposed: this.#disposed
    });
  }

  public dispose(): void {
    this.#disposed = true;
    const active = this.#activeEntry;
    this.#activeEntry = null;
    this.#active = false;
    active?.ownership?.complete();
    active?.resolve();
    this.#pending?.ownership?.complete();
    this.#pending?.resolve();
    this.#pending = null;
    this.#resolveIfIdle();
  }

  #drain(): void {
    if (this.#active) return;
    const pending = this.#pending;
    this.#pending = null;
    if (pending === null) {
      this.#resolveIfIdle();
      return;
    }
    this.#active = true;
    this.#activeEntry = pending;
    const operation = Promise.resolve().then(() => this.#apply(pending.snapshot));
    void operation.then(pending.resolve, pending.reject).finally(() => {
      pending.ownership?.complete();
      if (this.#activeEntry !== pending) return;
      this.#activeEntry = null;
      this.#active = false;
      this.#drain();
    });
  }

  #resolveIfIdle(): void {
    if (this.#active || this.#pending !== null) return;
    this.#resolveIdle?.();
    this.#resolveIdle = null;
    this.#idlePromise = null;
  }
}
