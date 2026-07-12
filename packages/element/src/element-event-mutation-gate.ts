import type { ElementPublicEvents } from "./element-public-events.js";

/** Defers listener-triggered public mutations until the DOM event transaction exits. */
export class ElementEventMutationGate {
  readonly #events: ElementPublicEvents;
  public constructor(events: ElementPublicEvents) { this.#events = events; }

  public defer(operation: () => void): boolean {
    if (!this.#events.active) return false;
    void this.#events.after(operation);
    return true;
  }

  public deferPromise<T>(operation: () => Promise<T>): Promise<T> | null {
    return this.#events.active ? this.#events.after(operation) : null;
  }
}
