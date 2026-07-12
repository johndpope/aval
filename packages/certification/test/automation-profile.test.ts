import { describe, expect, it } from "vitest";
import { functionalEngineResult } from "../src/automation-profile.js";

describe("functional browser engine labels", () => {
  it.each(["chromium", "firefox", "webkit"] as const)("never relabels Playwright %s as a branded certificate", (engine) => {
    const result = functionalEngineResult({ engine, exactProbe: "VideoDecoder.isConfigSupported(avc1.42E01E)", animationSupported: false, functionalAssertionsPassed: true, staticFallbackPassed: true });
    expect(result.claimLayer).toBe("functional-engine");
    expect(result.animatedStatus).toBe("unsupported");
    expect(result.staticFallbackStatus).toBe("passed");
    expect(result.label).not.toMatch(/\b(?:Chrome|Edge|Safari)\b/u);
  });
});
