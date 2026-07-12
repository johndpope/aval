import { describe, expect, it } from "vitest";
import { evaluateRuntimeCriteria } from "../src/runtime-criteria.js";

function passingInput() {
  const frames = Array.from({ length: 1_003 }, (_, deadlineOrdinal) => ({
    deadlineOrdinal,
    requiredContentOrdinal: deadlineOrdinal,
    submittedContentOrdinal: deadlineOrdinal,
    boundary: deadlineOrdinal >= 1_000,
    eligible: true,
    formatUnderflow: false,
    canvasSubmissionGapMicroseconds: deadlineOrdinal === 1_002 ? 49_999 : 33_333
  }));
  return {
    frames,
    idealContentFrameIntervalMicroseconds: 33_333,
    throughput: { outputFrames: 300, elapsedMicroseconds: 5_000_000, authoredFramesPerSecondMillionths: 30_000_000 },
    counterWindow: {
      baseline: { configure: 1, reset: 0, flush: 0, reconfigure: 0, seek: 0, stalePublications: 0, capViolations: 0, untrackedOwnedBytes: 0, terminalOwnedResources: 0 },
      terminal: { configure: 1, reset: 0, flush: 0, reconfigure: 0, seek: 0, stalePublications: 0, capViolations: 0, untrackedOwnedBytes: 0, terminalOwnedResources: 0 }
    }
  } as const;
}

describe("runtime certification criteria", () => {
  it("passes exact consecutive content through first and last boundaries", () => {
    const result = evaluateRuntimeCriteria(passingInput());
    expect(result.status).toBe("passed");
    expect(result.firstFailingDeadlineOrdinal).toBeNull();
    expect(result.throughputRatioMillionths).toBe(2_000_000);
    expect(result.counterDeltas.configure).toBe(0);
  });

  it.each([
    ["missing", null],
    ["duplicate", 999],
    ["wrong", 1002]
  ])("fails %s boundary content", (_name, submittedContentOrdinal) => {
    const input = passingInput();
    const frames = input.frames.map((frame) => frame.deadlineOrdinal === 1_000 ? { ...frame, submittedContentOrdinal } : frame);
    expect(evaluateRuntimeCriteria({ ...input, frames }).firstFailingDeadlineOrdinal).toBe(1_000);
  });

  it("fails boundary underflow, forbidden lifecycle counters, and insufficient throughput", () => {
    const input = passingInput();
    const frames = input.frames.map((frame) => frame.deadlineOrdinal === 1_001 ? { ...frame, formatUnderflow: true } : frame);
    const result = evaluateRuntimeCriteria({
      ...input,
      frames,
      throughput: { ...input.throughput, outputFrames: 299 },
      counterWindow: {
        baseline: input.counterWindow.baseline,
        terminal: { ...input.counterWindow.terminal, seek: 1 }
      }
    });
    expect(result.status).toBe("failed");
    expect(result.failures).toEqual(expect.arrayContaining(["format-underflow:1001", "throughput-sample-count-below-300", "counter-delta:seek:1>0"]));
  });

  it("excludes the initial decoder configure captured before the measured continuity window", () => {
    const result = evaluateRuntimeCriteria(passingInput());
    expect(result.status).toBe("passed");
    expect(result.counterDeltas).toMatchObject({ configure: 0, reset: 0, flush: 0, reconfigure: 0, seek: 0 });
  });

  it("permits only an explicitly declared measured-window counter allowance", () => {
    const input = passingInput();
    const result = evaluateRuntimeCriteria({
      ...input,
      counterWindow: {
        baseline: input.counterWindow.baseline,
        terminal: { ...input.counterWindow.terminal, configure: 2 },
        allowedDeltas: { configure: 1 }
      }
    });
    expect(result.status).toBe("passed");
    expect(result.counterDeltas.configure).toBe(1);
  });

  it("detects 1,000 independent off-by-one content mutations including first and last ordinals", () => {
    const input = passingInput();
    for (let ordinal = 0; ordinal < 1_000; ordinal += 1) {
      const frames = input.frames.map((frame) => frame.deadlineOrdinal === ordinal
        ? { ...frame, submittedContentOrdinal: frame.requiredContentOrdinal + 1 }
        : frame);
      const result = evaluateRuntimeCriteria({ ...input, frames });
      expect(result.status).toBe("failed");
      expect(result.firstFailingDeadlineOrdinal).toBe(ordinal);
    }
  });

  it("does not pass an all-ineligible frame ledger", () => {
    const input = passingInput();
    const result = evaluateRuntimeCriteria({
      ...input,
      frames: input.frames.map((frame) => ({ ...frame, eligible: false }))
    });
    expect(result.status).toBe("failed");
    expect(result.failures).toContain("eligible-frame-ledger-empty");
  });
});
