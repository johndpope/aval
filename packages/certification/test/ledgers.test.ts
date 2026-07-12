import { describe, expect, it } from "vitest";
import { CertificationFrameLedger } from "../src/frame-ledger.js";
import { CertificationResourceLedger } from "../src/resource-ledger.js";

describe("bounded certification ledgers", () => {
  it("records 1,000 append-only runtime submissions without display terminology", () => {
    const ledger = new CertificationFrameLedger(1_000);
    for (let ordinal = 0; ordinal < 1_000; ordinal += 1) ledger.append({
      deadlineOrdinal: ordinal,
      contentOrdinal: ordinal,
      requiredContentOrdinal: ordinal,
      eventAvailableBeforeCutoff: true,
      framePreparedBeforeCutoff: true,
      eligibleAnimationFrameOrdinal: ordinal,
      callbackStartMicroseconds: ordinal * 33_333,
      canvasSubmissionCompleteMicroseconds: ordinal * 33_333 + 1_000,
      gpuFence: "not-used",
      state: "idle",
      unit: "idle-body",
      localFrame: ordinal % 8
    });
    expect(ledger.snapshot()).toHaveLength(1_000);
    expect(() => ledger.append({ ...ledger.snapshot()[999]!, deadlineOrdinal: 1_000 })).toThrow(/limit/u);
    expect(Object.keys(ledger.snapshot()[0]!).some((key) => /display|scanout/iu.test(key))).toBe(false);
  });

  it("captures exact resource baseline, peak, and terminal counters immutably", () => {
    const ledger = new CertificationResourceLedger(3);
    ledger.append({ ordinal: 0, phase: "baseline", counters: { workers: 0, "owned-bytes": 0 } });
    ledger.append({ ordinal: 1, phase: "peak", counters: { workers: 2, "owned-bytes": 1_024 } });
    ledger.append({ ordinal: 2, phase: "terminal", counters: { workers: 0, "owned-bytes": 0 } });
    expect(ledger.snapshot()[2]?.counters).toEqual({ workers: 0, "owned-bytes": 0 });
    expect(() => ledger.append({ ordinal: 3, phase: "extra", counters: {} })).toThrow(/limit/u);
  });
});
