import { describe, expect, it } from "vitest";

import { MotionPreferenceBroker } from "../src/motion-preference-broker.js";
import { retryHostInstallationCleanup } from "../src/element-host-installation-error.js";

describe("MotionPreferenceBroker", () => {
  it("shares one listener and removes it after the last subscriber", () => {
    let listener: ((event: { matches: boolean }) => void) | null = null;
    let adds = 0;
    let removes = 0;
    const query = {
      matches: false,
      addEventListener: (_name: string, callback: (event: { matches: boolean }) => void) => {
        adds += 1;
        listener = callback;
      },
      removeEventListener: () => { removes += 1; }
    };
    const broker = new MotionPreferenceBroker({
      matchMedia: () => query
    } as unknown as Window);
    const values: boolean[] = [];
    const a = broker.subscribe((value) => values.push(value));
    const b = broker.subscribe((value) => values.push(value));
    expect(adds).toBe(1);
    (listener as unknown as (event: { matches: boolean }) => void)({ matches: true });
    expect(values).toEqual([true, true]);
    a.release();
    expect(removes).toBe(0);
    b.release();
    expect(removes).toBe(1);
  });

  it("rolls back listener faults and isolates callbacks and hostile removal", () => {
    let listener: ((event: { matches: boolean }) => void) | null = null;
    let throwAdd = true;
    let throwRemove = false;
    let throwMatches = false;
    const query = {
      get matches(): boolean {
        if (throwMatches) throw new Error("hostile matches");
        return false;
      },
      addEventListener: (_name: string, callback: (event: { matches: boolean }) => void) => {
        if (throwAdd) throw new Error("hostile add");
        listener = callback;
      },
      removeEventListener: () => {
        if (throwRemove) throw new Error("hostile remove");
        listener = null;
      }
    };
    const broker = new MotionPreferenceBroker({
      matchMedia: () => query
    } as unknown as Window);
    expect(() => broker.subscribe(() => undefined)).toThrow("hostile add");
    expect(broker.snapshot().subscribers).toBe(0);

    throwAdd = false;
    const hostile = broker.subscribe(() => { throw new Error("hostile subscriber"); });
    const values: boolean[] = [];
    const healthy = broker.subscribe((value) => values.push(value));
    expect(() => (listener as unknown as (event: { matches: boolean }) => void)({
      matches: true
    })).not.toThrow();
    expect(values).toEqual([true]);
    hostile.release();
    throwRemove = true;
    expect(healthy.release()).toBe(false);

    throwRemove = false;
    expect(healthy.release()).toBe(true);

    throwMatches = true;
    expect(broker.snapshot()).toMatchObject({ supported: true, current: null, subscribers: 0 });
  });

  it("retains a listener installed before the host add call throws", () => {
    let listener: ((event: { matches: boolean }) => void) | null = null;
    let throwRemove = true;
    const query = {
      matches: false,
      addEventListener: (_name: string, callback: (event: { matches: boolean }) => void) => {
        listener = callback;
        throw new Error("hostile add after install");
      },
      removeEventListener: () => {
        if (throwRemove) throw new Error("hostile remove");
        listener = null;
      }
    };
    const broker = new MotionPreferenceBroker({
      matchMedia: () => query
    } as unknown as Window);
    let failure: unknown;
    try { broker.subscribe(() => undefined); }
    catch (error) { failure = error; }
    expect(listener).not.toBeNull();
    expect(retryHostInstallationCleanup(failure)).toBe(false);
    throwRemove = false;
    expect(retryHostInstallationCleanup(failure)).toBe(true);
    expect(listener).toBeNull();
    expect(broker.snapshot().subscribers).toBe(0);
  });
});
