import { describe, expect, it } from "vitest";

import { createElementDiagnostics } from "../src/diagnostics.js";
import { ElementTrace } from "../src/element-trace.js";

describe("element diagnostics", () => {
  it("copies, freezes, bounds, and excludes transport identity", () => {
    const trace = new ElementTrace();
    for (let index = 0; index < 600; index += 1) trace.record("resize", 1);
    const diagnostics = createElementDiagnostics({
      elementGeneration: 1,
      sourceGeneration: 1,
      inputGeneration: 0,
      motionGeneration: 0,
      visibilityGeneration: 0,
      resizeGeneration: 600,
      connected: true,
      finalDisposed: false,
      readiness: "staticReady",
      mode: "static",
      assurance: null,
      staticReason: "reduced-motion",
      requestedState: "idle",
      visualState: "idle",
      isTransitioning: false,
      paused: false,
      effectivelyVisible: true,
      stateNames: ["idle"],
      eventNames: [],
      inputBindings: [],
      configuredMotion: "reduce",
      hostReducedMotion: true,
      autoplay: "visible",
      manualPlaying: true,
      fit: null,
      visibility: Object.freeze({
        documentVisible: true,
        intersecting: true,
        positiveBox: true,
        effectivelyVisible: true,
        observerSupported: true
      }),
      box: Object.freeze({ width: 100, height: 100 }),
      lastFailure: null,
      cleanup: null,
      elementOwnership: Object.freeze({
        listenerCount: 5,
        observerCount: 2,
        brokerSubscriptionCount: 3,
        timerCount: 0,
        pendingCommandCount: 1,
        failedReleaseCount: 0,
        retainedRetryCount: 0,
        releaseFailureCount: 0,
        completed: false
      }),
      terminalCleanup: null,
      counters: {
        prepare: 1,
        sourceReplacement: 0,
        pause: 0,
        resume: 0,
        underflow: 0,
        fallback: 1,
        contextRecovery: 0,
        cleanup: 0
      },
      runtime: null,
      trace
    }, true);
    expect(diagnostics.elementTrace).toHaveLength(512);
    expect(Object.isFrozen(diagnostics)).toBe(true);
    expect(diagnostics.elementOwnership).toMatchObject({
      listenerCount: 5,
      pendingCommandCount: 1,
      completed: false
    });
    expect(JSON.stringify(diagnostics)).not.toContain("http");
    expect(JSON.stringify(diagnostics)).not.toContain("integrity");
  });
});
