import { describe, expect, it } from "vitest";

import { ElementCommandSlot } from "../src/element-command-slot.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementCommandSlot", () => {
  it("joins duplicate keys and aborts a superseded distinct command", async () => {
    const slot = new ElementCommandSlot<Readonly<{
      sourceToken: number;
      name: string;
    }>>((left, right) =>
      left.sourceToken === right.sourceToken && left.name === right.name
    );
    const first = slot.request({ sourceToken: 1, name: "hover" });
    const duplicate = slot.request({ sourceToken: 1, name: "hover" });
    expect(duplicate.promise).toBe(first.promise);
    expect(duplicate.joined).toBe(true);

    const next = slot.request({ sourceToken: 1, name: "idle" });
    await expect(first.promise).rejects.toMatchObject({ name: "AbortError" });
    expect(slot.start(next.key)).toBe(true);
    expect(slot.start(next.key)).toBe(false);
    slot.resolve(next.key);
    await expect(next.promise).resolves.toBeUndefined();
    expect(slot.pending).toBe(0);
  });

  it("source invalidation rejects the captured command without migration", async () => {
    const slot = new ElementCommandSlot<number>((left, right) => left === right);
    const command = slot.request(7);
    slot.abort();
    await expect(command.promise).rejects.toMatchObject({ name: "AbortError" });
    expect(slot.current()).toBeNull();
  });

  it("leaves no ghost command when ownership capacity is exhausted", async () => {
    const ledger = new ElementOwnershipLedger({ maximumOwners: 1 });
    const blocker = ledger.acquire("command");
    const slot = new ElementCommandSlot<number>((left, right) => left === right, ledger);
    const rejected = slot.request(1);
    expect(rejected.accepted).toBe(false);
    await expect(rejected.promise).rejects.toThrow("ownership capacity exceeded");
    expect(slot.current()).toBeNull();
    blocker.complete();
    const request = slot.request(2);
    slot.resolve(2);
    await expect(request.promise).resolves.toBeUndefined();
    expect(ledger.snapshot().completed).toBe(true);
  });

  it("transfers the existing owner to a superseding command at capacity", async () => {
    const ledger = new ElementOwnershipLedger({ maximumOwners: 1 });
    const slot = new ElementCommandSlot<number>((left, right) => left === right, ledger);
    const first = slot.request(1);
    const replacement = slot.request(2);
    expect(replacement.accepted).toBe(true);
    await expect(first.promise).rejects.toMatchObject({ name: "AbortError" });
    expect(ledger.snapshot().pendingCommandCount).toBe(1);
    slot.resolve(2);
    await expect(replacement.promise).resolves.toBeUndefined();
    expect(ledger.snapshot().completed).toBe(true);
  });
});
