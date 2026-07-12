import { describe, expect, it } from "vitest";
import { evaluateOwnershipSettlement } from "../src/ownership-criteria.js";

describe("ownership criteria", () => {
  it("cannot claim settlement without explicit ownership counters", () => {
    expect(evaluateOwnershipSettlement({}, {}, {})).toMatchObject({
      status: "inconclusive",
      peakRegressions: ["ownership-counters-empty"]
    });
  });

  it("requires every explicit counter to return to its shared baseline", () => {
    expect(evaluateOwnershipSettlement({ workers: 1, leases: 0 }, { workers: 3, leases: 8 }, { workers: 1, leases: 0 }).status).toBe("passed");
    expect(evaluateOwnershipSettlement({ workers: 1 }, { workers: 3 }, { workers: 2 }).status).toBe("failed");
  });

  it("enforces declared peak caps without using heap telemetry as ownership truth", () => {
    const result = evaluateOwnershipSettlement({ bytes: 0 }, { bytes: 193 }, { bytes: 0 }, { bytes: 192 });
    expect(result.status).toBe("failed");
    expect(result.peakRegressions).toEqual(["bytes:193>192"]);
  });
});
