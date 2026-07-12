import { describe, expect, it } from "vitest";

import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementOwnershipLedger", () => {
  it("keeps failed physical ownership retryable until a later release succeeds", () => {
    const ledger = new ElementOwnershipLedger();
    const listener = ledger.acquire("listener");
    let hostile = true;
    expect(listener.release(() => {
      if (hostile) throw new Error("secret DOM failure");
    })).toBe(false);
    expect(ledger.snapshot()).toMatchObject({
      listenerCount: 1,
      failedReleaseCount: 1,
      retainedRetryCount: 1,
      releaseFailureCount: 1,
      completed: false
    });

    hostile = false;
    expect(ledger.retryAll()).toBe(true);
    expect(ledger.snapshot()).toMatchObject({
      listenerCount: 0,
      failedReleaseCount: 0,
      retainedRetryCount: 0,
      releaseFailureCount: 1,
      completed: true
    });
  });

  it("attempts every release independently and freezes bounded snapshots", () => {
    const ledger = new ElementOwnershipLedger({
      maximumOwners: 8,
      maximumReleaseFailures: 3
    });
    const observer = ledger.acquire("observer");
    const broker = ledger.acquire("broker");
    const frame = ledger.acquire("timer");
    const command = ledger.acquire("command");
    expect(observer.release(() => { throw new Error("observer"); })).toBe(false);
    expect(broker.release(() => { throw new Error("broker"); })).toBe(false);
    expect(frame.release(() => undefined)).toBe(true);
    expect(command.release(() => undefined)).toBe(true);
    const snapshot = ledger.snapshot();
    expect(snapshot).toMatchObject({
      observerCount: 1,
      brokerSubscriptionCount: 1,
      timerCount: 0,
      pendingCommandCount: 0,
      retainedRetryCount: 2,
      completed: false
    });
    expect(Object.isFrozen(snapshot)).toBe(true);
    expect(ledger.retryAll()).toBe(false);
    expect(ledger.snapshot().releaseFailureCount).toBe(3);
    expect(ledger.retryAll()).toBe(false);
    expect(ledger.snapshot().releaseFailureCount).toBe(3);
  });

  it("never reuses or loses precision in physical owner identities", () => {
    const ledger = new ElementOwnershipLedger({ maximumOwnerId: 2 });
    ledger.acquire("listener").complete();
    ledger.acquire("observer").complete();
    expect(() => ledger.acquire("command")).toThrow(
      "element ownership id sequence is exhausted"
    );
  });
});
