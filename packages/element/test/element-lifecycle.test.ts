import { describe, expect, it } from "vitest";

import { ElementLifecycle } from "../src/element-lifecycle.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementLifecycle", () => {
  it("cancels same-task move cleanup and retires a true disconnect", async () => {
    let connects = 0;
    let disconnects = 0;
    const lifecycle = new ElementLifecycle({
      onConnect: () => { connects += 1; },
      onDisconnect: async () => { disconnects += 1; },
      onDispose: async () => undefined
    });
    lifecycle.connect();
    lifecycle.disconnect();
    lifecycle.connect();
    await Promise.resolve();
    expect(disconnects).toBe(0);
    lifecycle.disconnect();
    await Promise.resolve();
    await Promise.resolve();
    expect(disconnects).toBe(1);
    expect(connects).toBe(2);
  });

  it("makes public disposal final and idempotent", async () => {
    let disposals = 0;
    const lifecycle = new ElementLifecycle({
      onConnect: () => undefined,
      onDisconnect: async () => undefined,
      onDispose: async () => { disposals += 1; }
    });
    const first = lifecycle.dispose();
    expect(lifecycle.dispose()).toBe(first);
    await first;
    lifecycle.connect();
    expect(lifecycle.connected).toBe(false);
    expect(disposals).toBe(1);
  });

  it("serializes overlapping real disconnects and final disposal", async () => {
    const releases: Array<() => void> = [];
    let disconnects = 0;
    let disposals = 0;
    const lifecycle = new ElementLifecycle({
      onConnect: () => undefined,
      onDisconnect: async () => {
        disconnects += 1;
        await new Promise<void>((resolve) => { releases.push(resolve); });
      },
      onDispose: async () => { disposals += 1; }
    });
    lifecycle.connect();
    lifecycle.disconnect();
    await Promise.resolve();
    await Promise.resolve();
    lifecycle.connect();
    lifecycle.disconnect();
    await Promise.resolve();
    expect(disconnects).toBe(1);
    const terminal = lifecycle.dispose();
    releases[0]!();
    for (let index = 0; index < 10 && disconnects < 2; index += 1) {
      await Promise.resolve();
    }
    expect(disconnects).toBe(2);
    expect(disposals).toBe(0);
    releases[1]!();
    await terminal;
    expect(disposals).toBe(1);
  });

  it("keeps terminal disposal retryable after an incomplete cleanup attempt", async () => {
    let hostile = true;
    let attempts = 0;
    const lifecycle = new ElementLifecycle({
      onConnect: () => undefined,
      onDisconnect: async () => undefined,
      onDispose: async () => {
        attempts += 1;
        if (hostile) throw new Error("normalized cleanup failure");
      }
    });
    await expect(lifecycle.dispose()).rejects.toThrow("normalized cleanup failure");
    expect(lifecycle.disposed).toBe(false);
    hostile = false;
    await lifecycle.dispose();
    expect(lifecycle.disposed).toBe(true);
    expect(attempts).toBe(2);
  });

  it("keeps connection truthful when disconnect command ownership cannot be acquired", async () => {
    const ledger = new ElementOwnershipLedger({ maximumOwners: 1 });
    const blocker = ledger.acquire("command");
    let disconnects = 0;
    const lifecycle = new ElementLifecycle({
      ledger,
      onConnect: () => undefined,
      onDisconnect: async () => { disconnects += 1; },
      onDispose: async () => undefined
    });
    lifecycle.connect();
    expect(() => lifecycle.disconnect()).toThrow("ownership capacity exceeded");
    expect(lifecycle.connected).toBe(true);
    blocker.complete();
    lifecycle.disconnect();
    await Promise.resolve();
    await Promise.resolve();
    expect(disconnects).toBe(1);
    await lifecycle.dispose();
    expect(ledger.snapshot().completed).toBe(true);
  });
});
