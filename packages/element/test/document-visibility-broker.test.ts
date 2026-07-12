import { describe, expect, it } from "vitest";

import { DocumentVisibilityBroker } from "../src/document-visibility-broker.js";
import { retryHostInstallationCleanup } from "../src/element-host-installation-error.js";

describe("DocumentVisibilityBroker", () => {
  it("shares exact document/page lifecycle listeners and removes the last set", () => {
    const window = new CountedEventTarget();
    const document = new FakeDocument(window);
    const broker = new DocumentVisibilityBroker(document as unknown as Document);
    const samples: Array<Readonly<{ visible: boolean; restored: boolean }>> = [];
    const first = broker.subscribe((sample) => samples.push(sample));
    const second = broker.subscribe(() => undefined);
    expect(first.current).toEqual({ visible: true, restored: false });
    expect(document.listenerCount).toBe(1);
    expect(window.listenerCount).toBe(2);

    document.visibilityState = "hidden";
    document.dispatchEvent(new Event("visibilitychange"));
    const pageShow = new Event("pageshow");
    Object.defineProperty(pageShow, "persisted", { value: true });
    window.dispatchEvent(pageShow);
    expect(samples).toEqual([
      { visible: false, restored: false },
      { visible: false, restored: true }
    ]);
    first.release();
    expect(document.listenerCount).toBe(1);
    second.release();
    expect(document.listenerCount).toBe(0);
    expect(window.listenerCount).toBe(0);
  });

  it("rolls back partial setup, isolates subscribers, and drains hostile removal", () => {
    const window = new CountedEventTarget();
    const document = new FakeDocument(window);
    const broker = new DocumentVisibilityBroker(document as unknown as Document);
    window.throwOnAdd = "pageshow";
    expect(() => broker.subscribe(() => undefined)).toThrow("hostile add pageshow");
    expect(document.listenerCount).toBe(0);
    expect(window.listenerCount).toBe(0);

    window.throwOnAdd = null;
    const hostile = broker.subscribe(() => { throw new Error("hostile subscriber"); });
    const samples: boolean[] = [];
    const healthy = broker.subscribe(({ visible }) => samples.push(visible));
    document.visibilityState = "hidden";
    expect(() => document.dispatchEvent(new Event("visibilitychange"))).not.toThrow();
    expect(samples).toEqual([false]);
    hostile.release();
    document.throwOnRemove = "visibilitychange";
    window.throwOnRemove = "pagehide";
    expect(healthy.release()).toBe(false);
    expect(document.removeAttempts).toContain("visibilitychange");
    expect(window.removeAttempts).toEqual(expect.arrayContaining(["pagehide", "pageshow"]));
    document.throwOnRemove = null;
    window.throwOnRemove = null;
    expect(healthy.release()).toBe(true);
    expect(document.listenerCount).toBe(0);
    expect(window.listenerCount).toBe(0);
  });

  it("retains a possibly-installed listener after add throws", () => {
    const window = new CountedEventTarget();
    const document = new FakeDocument(window);
    const broker = new DocumentVisibilityBroker(document as unknown as Document);
    window.throwAfterAdd = "pageshow";
    window.throwOnRemove = "pageshow";
    let failure: unknown;
    try { broker.subscribe(() => undefined); }
    catch (error) { failure = error; }
    expect(window.listenerCount).toBe(1);
    expect(retryHostInstallationCleanup(failure)).toBe(false);
    window.throwOnRemove = null;
    expect(retryHostInstallationCleanup(failure)).toBe(true);
    expect(window.listenerCount).toBe(0);
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

class FakeDocument extends CountedEventTarget {
  public visibilityState: "visible" | "hidden" = "visible";
  public constructor(public readonly defaultView: CountedEventTarget) { super(); }
}
