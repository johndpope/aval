import { describe, expect, it } from "vitest";

import { EngagementController } from "../src/engagement-controller.js";

describe("EngagementController", () => {
  it("emits only OR edges across pointer and focus", () => {
    const events: string[] = [];
    const engagement = new EngagementController((event) => events.push(event));
    engagement.setPointer(true);
    engagement.setFocus(true);
    engagement.setPointer(false);
    engagement.setFocus(false);
    expect(events).toEqual(["engagement.on", "engagement.off"]);
    expect(engagement.snapshot()).toEqual({ pointer: false, focus: false, engaged: false });
  });

  it("publishes the canonical initial sample even when both signals are false", () => {
    const events: string[] = [];
    const engagement = new EngagementController((event) => events.push(event));
    engagement.sample(false, false);
    engagement.sample(true, false);
    expect(events).toEqual(["engagement.off", "engagement.on"]);
  });
});
