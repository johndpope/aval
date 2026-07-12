import { hostInstallationError } from "./element-host-installation-error.js";

export interface MotionPreferenceSubscription {
  readonly supported: boolean;
  readonly current: boolean | null;
  release(): boolean;
}

type MotionSubscriber = (reduced: boolean) => void;

const BROKERS = new WeakMap<Window, MotionPreferenceBroker>();

export function subscribeMotionPreference(
  window: Window,
  subscriber: MotionSubscriber
): Readonly<MotionPreferenceSubscription> {
  let broker = BROKERS.get(window);
  if (broker === undefined) {
    broker = new MotionPreferenceBroker(window);
    BROKERS.set(window, broker);
  }
  return broker.subscribe(subscriber);
}

export class MotionPreferenceBroker {
  readonly #query: MediaQueryList | null;
  readonly #subscribers = new Set<MotionSubscriber>();
  #listening = false;

  public constructor(window: Window) {
    this.#query = typeof window.matchMedia === "function"
      ? window.matchMedia("(prefers-reduced-motion: reduce)")
      : null;
  }

  public subscribe(subscriber: MotionSubscriber): Readonly<MotionPreferenceSubscription> {
    if (typeof subscriber !== "function") throw new TypeError("motion subscriber must be a function");
    this.#subscribers.add(subscriber);
    let current: boolean | null;
    try {
      if (this.#query !== null && !this.#listening) {
        this.#listening = true;
        this.#query.addEventListener("change", this.#change);
      }
      current = this.#query?.matches ?? null;
    } catch (error) {
      this.#subscribers.delete(subscriber);
      throw hostInstallationError(error, () => this.#unlisten());
    }
    let subscriberRemoved = false;
    let released = false;
    return Object.freeze({
      supported: this.#query !== null,
      current,
      release: () => {
        if (released) return true;
        if (!subscriberRemoved) {
          subscriberRemoved = true;
          this.#subscribers.delete(subscriber);
        }
        if (this.#subscribers.size === 0 && this.#query !== null && this.#listening) {
          released = this.#unlisten();
          return released;
        }
        released = true;
        return true;
      }
    });
  }

  public snapshot(): Readonly<{ supported: boolean; current: boolean | null; subscribers: number }> {
    let current: boolean | null = null;
    try { current = this.#query?.matches ?? null; } catch { /* hostile query is unreadable */ }
    return Object.freeze({
      supported: this.#query !== null,
      current,
      subscribers: this.#subscribers.size
    });
  }

  readonly #change = (event: MediaQueryListEvent): void => {
    const reduced = event.matches;
    for (const subscriber of [...this.#subscribers]) {
      try { subscriber(reduced); } catch { /* subscribers remain independent */ }
    }
  };

  #unlisten(): boolean {
    if (this.#query === null || !this.#listening) return true;
    try {
      this.#query.removeEventListener("change", this.#change);
      this.#listening = false;
      return true;
    } catch {
      return false;
    }
  }
}
