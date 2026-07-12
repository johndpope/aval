import { describe, expect, it } from "vitest";

import { ElementReconcileLane } from "../src/element-reconcile-lane.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementReconcileLane", () => {
  it("runs one active revision and only the newest pending revision", async () => {
    let release!: () => void;
    const applied: number[] = [];
    const ledger = new ElementOwnershipLedger();
    const lane = new ElementReconcileLane<number>(async (revision) => {
      applied.push(revision);
      if (revision === 1) {
        await new Promise<void>((resolve) => { release = resolve; });
      }
    }, ledger);
    const first = lane.submit(1);
    await Promise.resolve();
    const superseded: Promise<void>[] = [];
    for (let revision = 2; revision <= 100; revision += 1) {
      superseded.push(lane.submit(revision));
    }
    await Promise.all(superseded.slice(0, -1));
    expect(lane.snapshot()).toEqual({ active: 1, pending: 1, disposed: false });
    expect(ledger.snapshot().pendingCommandCount).toBe(2);
    expect(applied).toEqual([1]);
    release();
    await Promise.all([first, superseded.at(-1), lane.settled()]);
    expect(applied).toEqual([1, 100]);
    expect(lane.snapshot()).toEqual({ active: 0, pending: 0, disposed: false });
    expect(ledger.snapshot().pendingCommandCount).toBe(0);
  });

  it("does not retain a ghost pending revision after command acquisition fails", async () => {
    let release!: () => void;
    const ledger = new ElementOwnershipLedger({ maximumOwners: 1 });
    const lane = new ElementReconcileLane<number>(async () => {
      await new Promise<void>((resolve) => { release = resolve; });
    }, ledger);
    const active = lane.submit(1);
    await Promise.resolve();
    await expect(lane.submit(2)).rejects.toThrow("ownership capacity exceeded");
    expect(lane.snapshot()).toEqual({ active: 1, pending: 0, disposed: false });
    release();
    await active;
    await lane.settled();
    expect(ledger.snapshot().completed).toBe(true);
  });

  it("retains the newest pending revision by transferring its owner at capacity", async () => {
    let release!: () => void;
    const applied: number[] = [];
    const ledger = new ElementOwnershipLedger({ maximumOwners: 2 });
    const lane = new ElementReconcileLane<number>(async (revision) => {
      applied.push(revision);
      if (revision === 1) {
        await new Promise<void>((resolve) => { release = resolve; });
      }
    }, ledger);
    const active = lane.submit(1);
    await Promise.resolve();
    const superseded = lane.submit(2);
    const newest = lane.submit(3);
    await expect(superseded).resolves.toBeUndefined();
    expect(ledger.snapshot().pendingCommandCount).toBe(2);
    expect(lane.snapshot()).toEqual({ active: 1, pending: 1, disposed: false });
    release();
    await Promise.all([active, newest, lane.settled()]);
    expect(applied).toEqual([1, 3]);
    expect(ledger.snapshot().completed).toBe(true);
  });

  it("terminal disposal detaches a blocked active revision and drops pending work", async () => {
    let release!: () => void;
    const applied: number[] = [];
    const ledger = new ElementOwnershipLedger();
    const lane = new ElementReconcileLane<number>(async (revision) => {
      applied.push(revision);
      await new Promise<void>((resolve) => { release = resolve; });
    }, ledger);
    const active = lane.submit(1);
    await Promise.resolve();
    const pending = lane.submit(2);
    expect(lane.snapshot()).toEqual({ active: 1, pending: 1, disposed: false });

    lane.dispose();
    await expect(Promise.all([active, pending, lane.settled()])).resolves.toEqual([
      undefined,
      undefined,
      undefined
    ]);
    expect(lane.snapshot()).toEqual({ active: 0, pending: 0, disposed: true });
    expect(ledger.snapshot().completed).toBe(true);

    release();
    await Promise.resolve();
    await Promise.resolve();
    expect(applied).toEqual([1]);
    expect(lane.snapshot()).toEqual({ active: 0, pending: 0, disposed: true });
  });
});
