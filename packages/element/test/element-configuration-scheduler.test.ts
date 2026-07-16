import { describe, expect, it } from "vitest";

import {
  ElementConfigurationScheduler,
  type ElementConfigurationAuthority
} from "../src/element-configuration-scheduler.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementConfigurationScheduler", () => {
  it("does not publish or mutate scheduled state when ownership acquisition fails", async () => {
    const ledger = new ElementOwnershipLedger({ maximumOwners: 1 });
    const blocker = ledger.acquire("command");
    let publications = 0;
    const scheduler = new ElementConfigurationScheduler({
      host: host(),
      ledger,
      authority: authority(() => { publications += 1; })
    });
    expect(() => scheduler.schedule()).toThrow("ownership capacity exceeded");
    expect(publications).toBe(0);
    blocker.complete();
    scheduler.schedule();
    await Promise.resolve();
    expect(publications).toBe(1);
    expect(ledger.snapshot()).toMatchObject({ pendingCommandCount: 0, completed: true });
  });

  it("always releases its command owner when authority publication throws", async () => {
    const ledger = new ElementOwnershipLedger();
    let failures = 0;
    const scheduler = new ElementConfigurationScheduler({
      host: host(),
      ledger,
      authority: {
        configurationReady: () => { throw new Error("hostile authority"); },
        configurationFailed: () => { failures += 1; }
      }
    });
    scheduler.schedule();
    await Promise.resolve();
    expect(failures).toBe(1);
    expect(ledger.snapshot()).toMatchObject({ pendingCommandCount: 0, completed: true });
  });
});

function authority(publish: () => void): ElementConfigurationAuthority {
  return {
    configurationReady: publish,
    configurationFailed: () => undefined
  };
}

function host(): HTMLElement {
  return {
    getAttribute: () => null,
    children: {
      length: 0,
      item: () => null
    }
  } as unknown as HTMLElement;
}
