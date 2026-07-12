import { describe, expect, it } from "vitest";

import { DomEventBridge } from "../src/dom-event-bridge.js";

class DetailEvent<T> extends Event {
  public readonly detail: Readonly<T>;
  public constructor(type: string, detail: Readonly<T>) {
    super(type);
    this.detail = detail;
  }
}

describe("DomEventBridge", () => {
  it("stages getters before immutable public event dispatch", () => {
    const target = new EventTarget();
    let requested: string | null = "idle";
    const observed: unknown[] = [];
    target.addEventListener("requestedstatechange", (event) => {
      observed.push({
        requested,
        detail: (event as DetailEvent<unknown>).detail
      });
    });
    const bridge = new DomEventBridge({
      target,
      generation: 3,
      stage: {
        readiness: () => undefined,
        requestedState: (value) => { requested = value; },
        visualState: () => undefined,
        transitioning: () => undefined,
        snapshot: () => ({ requestedState: requested, visualState: "idle" })
      },
      createEvent: (type, detail) => new DetailEvent(type, detail) as unknown as CustomEvent<typeof detail>
    });
    bridge.runtime({
      type: "requestedstatechange",
      from: "idle",
      to: "engaged",
      sequence: 4
    });
    expect(observed).toEqual([{
      requested: "engaged",
      detail: { generation: 3, from: "idle", to: "engaged", sequence: 4 }
    }]);
    expect(Object.isFrozen((observed[0] as { detail: object }).detail)).toBe(true);
  });

  it("publishes each incident already coalesced by the canonical runtime", () => {
    const target = new EventTarget();
    const counts: number[] = [];
    target.addEventListener("underflow", (event) => {
      counts.push((event as DetailEvent<{ cumulativeCount: number }>).detail.cumulativeCount);
    });
    const bridge = new DomEventBridge({
      target,
      generation: 1,
      stage: {
        readiness: () => undefined,
        requestedState: () => undefined,
        visualState: () => undefined,
        transitioning: () => undefined,
        snapshot: () => ({ requestedState: null, visualState: null })
      },
      createEvent: (type, detail) => new DetailEvent(type, detail) as unknown as CustomEvent<typeof detail>
    });
    bridge.underflow(7n);
    bridge.underflow(8n);
    expect(counts).toEqual([1, 2]);
  });
});
