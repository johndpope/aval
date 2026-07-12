import { describe, expect, it } from "vitest";

import { ElementPrepareReservations } from "../src/element-prepare-reservations.js";

describe("ElementPrepareReservations", () => {
  it("reserves capacity before blocked work and releases every terminal path", async () => {
    const reservations = new ElementPrepareReservations(64);
    let releaseLane!: () => void;
    const lane = new Promise<void>((resolve) => { releaseLane = resolve; });
    const callers = Array.from({ length: 64 }, async () => {
      const release = reservations.reserve();
      try { await lane; }
      finally { release(); }
    });
    expect(reservations.active).toBe(64);
    expect(() => reservations.reserve()).toThrow("prepare waiter capacity exceeded");
    releaseLane();
    await Promise.all(callers);
    expect(reservations.active).toBe(0);
    const release = reservations.reserve();
    release();
  });
});
