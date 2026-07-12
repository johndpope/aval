import type { ElementOwnershipSnapshot } from "./element-ownership-ledger.js";
import { nextElementSequence } from "./element-sequence.js";

export class ElementConfigurationFailureTracker {
  readonly #attributes = new Set<string>();

  public update(
    failures: readonly Readonly<{ attribute: string }>[],
    connected: boolean
  ): number {
    const current = new Set(failures.map(({ attribute }) => attribute));
    for (const attribute of this.#attributes) {
      if (!current.has(attribute)) this.#attributes.delete(attribute);
    }
    let publications = 0;
    if (connected) {
      for (const failure of failures) {
        if (!this.#attributes.has(failure.attribute)) {
          this.#attributes.add(failure.attribute);
          publications += 1;
        }
      }
    }
    return publications;
  }

  public clear(): void { this.#attributes.clear(); }
}

export class ElementCleanupFailureTracker {
  #generation = 0;
  #reported = -1;

  public begin(): void {
    this.#generation = nextElementSequence(this.#generation, "cleanup generation");
  }

  public shouldReport(
    operationComplete: boolean,
    ownership: Readonly<ElementOwnershipSnapshot>
  ): boolean {
    if (
      operationComplete && ownership.failedReleaseCount === 0 ||
      this.#reported === this.#generation
    ) return false;
    this.#reported = this.#generation;
    return true;
  }
}
