import { hostInstallationError } from "./element-host-installation-error.js";

type DprSubscriber = (value: number) => void;

const BROKERS = new WeakMap<Window, DprBroker>();

export function subscribeDpr(
  window: Window,
  subscriber: DprSubscriber
): Readonly<{ current: number; release(): boolean }> {
  let broker = BROKERS.get(window);
  if (broker === undefined) {
    broker = new DprBroker(window);
    BROKERS.set(window, broker);
  }
  return broker.subscribe(subscriber);
}

export class DprBroker {
  readonly #window: Window;
  readonly #subscribers = new Set<DprSubscriber>();
  #current: number;
  #query: MediaQueryList | null = null;
  #windowListening = false;
  #viewport: VisualViewport | null = null;
  #viewportListening = false;

  public constructor(window: Window) {
    this.#window = window;
    let current = 1;
    try { current = validDpr(window.devicePixelRatio) ?? 1; } catch { /* default */ }
    this.#current = current;
  }

  public subscribe(subscriber: DprSubscriber): Readonly<{
    current: number;
    release(): boolean;
  }> {
    this.#subscribers.add(subscriber);
    try { this.#listen(); }
    catch (error) {
      this.#subscribers.delete(subscriber);
      throw hostInstallationError(error, () => this.#unlisten());
    }
    let subscriberRemoved = false;
    let released = false;
    return Object.freeze({
      current: this.#current,
      release: () => {
        if (released) return true;
        if (!subscriberRemoved) {
          subscriberRemoved = true;
          this.#subscribers.delete(subscriber);
        }
        if (this.#subscribers.size > 0) {
          released = true;
          return true;
        }
        released = this.#unlisten();
        return released;
      }
    });
  }

  readonly #sample = (): void => {
    let next: number | null;
    try { next = validDpr(this.#window.devicePixelRatio); }
    catch { return; }
    if (next === null || next === this.#current) return;
    this.#current = next;
    try { this.#rebuildQuery(); } catch { /* resize listeners remain authoritative */ }
    for (const subscriber of [...this.#subscribers]) {
      try { subscriber(next); } catch { /* subscribers remain independent */ }
    }
  };

  #listen(): void {
    this.#current = validDpr(this.#window.devicePixelRatio) ?? 1;
    if (!this.#windowListening) {
      this.#windowListening = true;
      this.#window.addEventListener("resize", this.#sample);
    }
    if (this.#viewport === null) this.#viewport = this.#window.visualViewport;
    if (this.#viewport !== null && !this.#viewportListening) {
      this.#viewportListening = true;
      this.#viewport.addEventListener("resize", this.#sample);
    }
    if (this.#query === null) this.#rebuildQuery();
  }

  #unlisten(): boolean {
    let complete = true;
    if (this.#windowListening) {
      try {
        this.#window.removeEventListener("resize", this.#sample);
        this.#windowListening = false;
      } catch { complete = false; }
    }
    if (this.#viewportListening) {
      try {
        this.#viewport?.removeEventListener("resize", this.#sample);
        this.#viewportListening = false;
      } catch { complete = false; }
    }
    if (this.#query !== null) {
      try {
        this.#query.removeEventListener("change", this.#sample);
        this.#query = null;
      } catch { complete = false; }
    }
    if (!this.#viewportListening) this.#viewport = null;
    return complete &&
      !this.#windowListening && !this.#viewportListening && this.#query === null;
  }

  #rebuildQuery(): void {
    const previous = this.#query;
    if (previous !== null) {
      try { previous.removeEventListener("change", this.#sample); }
      catch { return; }
      this.#query = null;
    }
    if (typeof this.#window.matchMedia !== "function") return;
    let next: MediaQueryList | null = null;
    try {
      next = this.#window.matchMedia(`(resolution: ${String(this.#current)}dppx)`);
      this.#query = next;
      next.addEventListener("change", this.#sample);
    } catch {
      try {
        next?.removeEventListener("change", this.#sample);
        if (this.#query === next) this.#query = null;
      } catch { /* retain the possibly-installed query for release retry */ }
    }
  }
}

function validDpr(value: number): number | null {
  return Number.isFinite(value) && value > 0 ? value : null;
}
