import { describe, expect, it } from "vitest";

import { DprBroker } from "../src/dpr-broker.js";
import { retryHostInstallationCleanup } from "../src/element-host-installation-error.js";

describe("DprBroker", () => {
  it("rebuilds the resolution query, ignores hostile samples, and tears down", () => {
    const window = new FakeWindow();
    const broker = new DprBroker(window as unknown as Window);
    const samples: number[] = [];
    const subscription = broker.subscribe((value) => samples.push(value));
    expect(subscription.current).toBe(1);
    expect(window.matchQueries).toEqual(["(resolution: 1dppx)"]);

    window.devicePixelRatio = Number.NaN;
    window.dispatchEvent(new Event("resize"));
    window.devicePixelRatio = 1.25;
    window.query.dispatchEvent(new Event("change"));
    expect(samples).toEqual([1.25]);
    expect(window.matchQueries).toEqual([
      "(resolution: 1dppx)",
      "(resolution: 1.25dppx)"
    ]);
    subscription.release();
    expect(window.listenerCount).toBe(0);
    expect(window.query.listenerCount).toBe(0);

    window.devicePixelRatio = 2;
    const reconnected = broker.subscribe((value) => samples.push(value));
    expect(reconnected.current).toBe(2);
    expect(window.matchQueries.at(-1)).toBe("(resolution: 2dppx)");
    reconnected.release();
  });

  it("rolls back partial listeners and isolates hostile samples and subscribers", () => {
    const window = new FakeWindow();
    const broker = new DprBroker(window as unknown as Window);
    window.visualViewport.throwOnAdd = "resize";
    expect(() => broker.subscribe(() => undefined)).toThrow("hostile add resize");
    expect(window.listenerCount).toBe(0);
    expect(window.visualViewport.listenerCount).toBe(0);

    window.visualViewport.throwOnAdd = null;
    const hostile = broker.subscribe(() => { throw new Error("hostile subscriber"); });
    const samples: number[] = [];
    const healthy = broker.subscribe((value) => samples.push(value));
    window.throwOnDprRead = true;
    expect(() => window.dispatchEvent(new Event("resize"))).not.toThrow();
    expect(samples).toEqual([]);
    window.throwOnDprRead = false;
    window.devicePixelRatio = 2;
    window.dispatchEvent(new Event("resize"));
    expect(samples).toEqual([2]);

    hostile.release();
    window.throwOnRemove = "resize";
    window.visualViewport.throwOnRemove = "resize";
    window.query.throwOnRemove = "change";
    expect(healthy.release()).toBe(false);
    expect(window.removeAttempts).toContain("resize");
    expect(window.visualViewport.removeAttempts).toContain("resize");
    expect(window.query.removeAttempts).toContain("change");
    window.throwOnRemove = null;
    window.visualViewport.throwOnRemove = null;
    window.query.throwOnRemove = null;
    expect(healthy.release()).toBe(true);
    expect(window.listenerCount).toBe(0);
    expect(window.visualViewport.listenerCount).toBe(0);
    expect(window.query.listenerCount).toBe(0);
  });

  it("retains a window listener installed before add throws", () => {
    const window = new FakeWindow();
    const broker = new DprBroker(window as unknown as Window);
    window.throwAfterAdd = "resize";
    window.throwOnRemove = "resize";
    let failure: unknown;
    try { broker.subscribe(() => undefined); }
    catch (error) { failure = error; }
    expect(window.listenerCount).toBe(1);
    expect(retryHostInstallationCleanup(failure)).toBe(false);
    window.throwOnRemove = null;
    expect(retryHostInstallationCleanup(failure)).toBe(true);
    expect(window.listenerCount).toBe(0);
  });

  it("retains a resolution query whose add and rollback both throw", () => {
    const window = new FakeWindow();
    window.queryThrowAfterAdd = "change";
    window.queryThrowOnRemove = "change";
    const broker = new DprBroker(window as unknown as Window);
    const subscription = broker.subscribe(() => undefined);
    expect(window.query.listenerCount).toBe(1);
    expect(subscription.release()).toBe(false);
    window.query.throwOnRemove = null;
    expect(subscription.release()).toBe(true);
    expect(window.query.listenerCount).toBe(0);
  });
});

class CountedEventTarget extends EventTarget {
  public throwOnAdd: string | null = null;
  public throwAfterAdd: string | null = null;
  public throwOnRemove: string | null = null;
  public readonly removeAttempts: string[] = [];
  readonly #listeners = new Map<string, Set<unknown>>();
  public get listenerCount(): number {
    return [...this.#listeners.values()].reduce((sum, listeners) => sum + listeners.size, 0);
  }
  public override addEventListener(...arguments_: Parameters<EventTarget["addEventListener"]>): void {
    if (arguments_[0] === this.throwOnAdd) throw new Error(`hostile add ${arguments_[0]}`);
    super.addEventListener(...arguments_);
    const listeners = this.#listeners.get(arguments_[0]) ?? new Set();
    if (arguments_[1] !== null) listeners.add(arguments_[1]);
    this.#listeners.set(arguments_[0], listeners);
    if (arguments_[0] === this.throwAfterAdd) throw new Error(`hostile add after ${arguments_[0]}`);
  }
  public override removeEventListener(...arguments_: Parameters<EventTarget["removeEventListener"]>): void {
    this.removeAttempts.push(arguments_[0]);
    if (arguments_[0] === this.throwOnRemove) throw new Error(`hostile remove ${arguments_[0]}`);
    super.removeEventListener(...arguments_);
    if (arguments_[1] !== null) this.#listeners.get(arguments_[0])?.delete(arguments_[1]);
  }
}

class FakeMediaQuery extends CountedEventTarget {
  public matches = false;
  public media = "";
}

class FakeWindow extends CountedEventTarget {
  #devicePixelRatio = 1;
  public throwOnDprRead = false;
  public readonly visualViewport = new CountedEventTarget();
  public query = new FakeMediaQuery();
  public queryThrowAfterAdd: string | null = null;
  public queryThrowOnRemove: string | null = null;
  public readonly matchQueries: string[] = [];
  public get devicePixelRatio(): number {
    if (this.throwOnDprRead) throw new Error("hostile DPR read");
    return this.#devicePixelRatio;
  }
  public set devicePixelRatio(value: number) { this.#devicePixelRatio = value; }
  public matchMedia(value: string): FakeMediaQuery {
    this.matchQueries.push(value);
    this.query = new FakeMediaQuery();
    this.query.media = value;
    this.query.throwAfterAdd = this.queryThrowAfterAdd;
    this.query.throwOnRemove = this.queryThrowOnRemove;
    return this.query;
  }
}
