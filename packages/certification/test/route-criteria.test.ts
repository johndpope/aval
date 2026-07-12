import { describe, expect, it } from "vitest";
import { evaluateRouteCriteria, type RouteLedgerEntry } from "../src/route-criteria.js";

function entry(requestOrdinal: number): RouteLedgerEntry {
  const requestContentOrdinal = requestOrdinal * 2;
  return {
    requestOrdinal,
    kind: requestOrdinal % 2 === 0 ? "portal" : "reversal",
    selectedWaitFrames: requestOrdinal % 8,
    maximumWaitFrames: 7,
    requiredFirstContentOrdinal: requestOrdinal % 2 === 0 ? requestContentOrdinal + (requestOrdinal % 8) + 1 : requestContentOrdinal + 1,
    actualFirstContentOrdinal: requestOrdinal % 2 === 0 ? requestContentOrdinal + (requestOrdinal % 8) + 1 : requestContentOrdinal + 1,
    requestContentOrdinal,
    newestAcceptedSequence: requestOrdinal + 1,
    settledSequence: requestOrdinal + 1
  };
}

describe("route certification criteria", () => {
  it("cannot pass without route evidence", () => {
    expect(evaluateRouteCriteria([])).toMatchObject({ status: "inconclusive", failures: ["route-ledger-empty"] });
  });

  it("passes 1,000 portal/reversal positions within authored bounds", () => {
    expect(evaluateRouteCriteria(Array.from({ length: 1_000 }, (_, ordinal) => entry(ordinal))).status).toBe("passed");
  });

  it("identifies wait, entry, adjacent-reversal, and latest-wins divergence", () => {
    const base = entry(3);
    const result = evaluateRouteCriteria([{ ...base, selectedWaitFrames: 8, actualFirstContentOrdinal: null, requiredFirstContentOrdinal: base.requestContentOrdinal + 2, settledSequence: 1 }]);
    expect(result.status).toBe("failed");
    expect(result.failures).toEqual(expect.arrayContaining([
      "route-wait-exceeded:3",
      "wrong-route-entry-content:3",
      "reversal-not-adjacent-next-frame:3",
      "latest-wins-divergence:3"
    ]));
  });
});
