import {
  readElementConfiguration,
  type ElementConfigurationRead
} from "./element-configuration.js";
import { readElementSourceCandidates } from "./element-source-candidates.js";
import type {
  ElementOwnershipHandle,
  ElementOwnershipLedger
} from "./element-ownership-ledger.js";
import { nextElementSequence } from "./element-sequence.js";

export interface ElementConfigurationAuthority {
  configurationReady(read: Readonly<ElementConfigurationRead>): void;
  configurationFailed(error: unknown): void;
}

/** Owns only same-task attribute-read coalescing; runtime effects stay in the actor. */
export class ElementConfigurationScheduler {
  readonly #host: HTMLElement;
  readonly #ledger: ElementOwnershipLedger;
  readonly #authority: ElementConfigurationAuthority;
  #scheduled = false;
  #token = 0;
  #ownership: ElementOwnershipHandle | null = null;
  #closed = false;

  public constructor(input: Readonly<{
    host: HTMLElement;
    ledger: ElementOwnershipLedger;
    authority: ElementConfigurationAuthority;
  }>) {
    this.#host = input.host;
    this.#ledger = input.ledger;
    this.#authority = input.authority;
  }

  public schedule(): void {
    if (this.#scheduled || this.#closed) return;
    const ownership = this.#ledger.acquire("command");
    let token: number;
    try {
      token = this.#token = nextElementSequence(this.#token, "configuration schedule");
    } catch (error) {
      ownership.complete();
      throw error;
    }
    this.#scheduled = true;
    this.#ownership = ownership;
    queueMicrotask(() => {
      try {
        if (this.#scheduled && !this.#closed && token === this.#token) this.#publish();
      } catch (error) {
        this.#authority.configurationFailed(error);
      } finally {
        ownership.complete();
        if (this.#ownership === ownership) this.#ownership = null;
      }
    });
  }

  public flush(): void {
    if (!this.#scheduled || this.#closed) return;
    const token = nextElementSequence(this.#token, "configuration schedule");
    this.#scheduled = false;
    this.#token = token;
    this.#ownership?.complete();
    this.#ownership = null;
    this.#publish();
  }

  public close(): void {
    if (this.#closed) return;
    const token = nextElementSequence(this.#token, "configuration schedule");
    this.#closed = true;
    this.#scheduled = false;
    this.#token = token;
    this.#ownership?.complete();
    this.#ownership = null;
  }

  #publish(): void {
    this.#scheduled = false;
    this.#authority.configurationReady(
      readElementConfiguration(
        (name) => this.#host.getAttribute(name),
        readElementSourceCandidates(this.#host)
      )
    );
  }
}
