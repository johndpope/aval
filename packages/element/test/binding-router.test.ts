import { describe, expect, it } from "vitest";

import { BindingRouter } from "../src/binding-router.js";

describe("BindingRouter", () => {
  it("routes manifest sources to arbitrary authored events only", () => {
    const events: string[] = [];
    const router = new BindingRouter((event) => {
      events.push(event);
      return true;
    });
    router.install([
      { source: "engagement.on", event: "orb.wake" },
      { source: "engagement.off", event: "orb.sleep" }
    ]);
    expect(router.route("engagement.on")).toBe(true);
    expect(router.route("activate")).toBe(false);
    router.setEnabled(false);
    expect(router.route("engagement.off")).toBe(false);
    expect(events).toEqual(["orb.wake"]);
    expect(Object.isFrozen(router.snapshot())).toBe(true);
  });

  it("rejects hostile duplicate sources", () => {
    const router = new BindingRouter(() => true);
    expect(() => router.install([
      { source: "activate", event: "first" },
      { source: "activate", event: "second" }
    ])).toThrow("unique");
  });
});
