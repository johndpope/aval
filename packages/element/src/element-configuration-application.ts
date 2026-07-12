import {
  diffElementConfiguration,
  type ElementConfigurationChangeSet,
  type ElementConfigurationRead
} from "./element-configuration.js";
import type { ElementDesiredSnapshot, ElementDesiredState } from "./element-desired-state.js";
import { ElementConfigurationFailureTracker } from "./element-reconciler-trackers.js";

export interface ElementConfigurationInspection {
  readonly changes: Readonly<ElementConfigurationChangeSet>;
  readonly requiresSourceInvalidation: boolean;
}

export interface ElementConfigurationApplicationResult {
  readonly snapshot: Readonly<ElementDesiredSnapshot>;
  readonly changes: Readonly<ElementConfigurationChangeSet>;
  readonly failurePublications: number;
}

/** Attribute normalization/diff mechanics; it performs no DOM/runtime effects. */
export class ElementConfigurationApplication {
  readonly #desired: ElementDesiredState;
  readonly #failures = new ElementConfigurationFailureTracker();
  #identityInvalidated = false;

  public constructor(desired: ElementDesiredState) { this.#desired = desired; }
  public markIdentityInvalidated(): void { this.#identityInvalidated = true; }

  public inspect(
    read: Readonly<ElementConfigurationRead>
  ): Readonly<ElementConfigurationInspection> {
    const changes = diffElementConfiguration(
      this.#desired.snapshot().configuration,
      read.configuration
    );
    return Object.freeze({
      changes,
      requiresSourceInvalidation: changes.retrievalIdentity && !this.#identityInvalidated
    });
  }

  public commit(
    read: Readonly<ElementConfigurationRead>,
    inspection: Readonly<ElementConfigurationInspection>,
    connected: boolean
  ): Readonly<ElementConfigurationApplicationResult> {
    this.#identityInvalidated = false;
    let snapshot = this.#desired.configure(read.configuration);
    if (inspection.changes.state) {
      snapshot = read.configuration.state === null
        ? this.#desired.requestInitialState()
        : this.#desired.requestState(read.configuration.state);
    }
    return Object.freeze({
      snapshot,
      changes: inspection.changes,
      failurePublications: this.#failures.update(read.failures, connected)
    });
  }

  public clear(): void { this.#failures.clear(); }
}
