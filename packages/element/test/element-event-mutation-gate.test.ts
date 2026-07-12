import { describe, expect, it } from "vitest";

import { ElementEventMutationGate } from "../src/element-event-mutation-gate.js";
import { ElementPublicEvents } from "../src/element-public-events.js";

describe("ElementEventMutationGate", () => {
  it("defers source/dispose-style mutations until the active event transaction exits", async () => {
    const events = new ElementPublicEvents({} as HTMLElement);
    const gate = new ElementEventMutationGate(events);
    const order: string[] = [];
    events.transaction(true);
    expect(gate.defer(() => { order.push("source"); })).toBe(true);
    const disposal = gate.deferPromise(async () => { order.push("dispose"); });
    order.push("listener-end");
    expect(order).toEqual(["listener-end"]);
    events.transaction(false);
    await disposal;
    expect(order).toEqual(["listener-end", "source", "dispose"]);
  });
});
