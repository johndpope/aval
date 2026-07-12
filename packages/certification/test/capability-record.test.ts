import { describe, expect, it } from "vitest";
import { capabilityOutcome, REQUIRED_ANIMATED_CAPABILITY_PROBES } from "../src/capability-record.js";

function probes(supported = true) {
  return REQUIRED_ANIMATED_CAPABILITY_PROBES.map((id) => ({ id, supported, exactConfiguration: `${id}=exact`, detail: "probe completed" }));
}

describe("animated capability outcome", () => {
  it("requires the complete exact prerequisite set before saying supported", () => {
    expect(capabilityOutcome(probes())).toBe("supported");
    expect(capabilityOutcome([])).toBe("inconclusive");
    expect(capabilityOutcome(probes().slice(1))).toBe("inconclusive");
  });

  it("distinguishes a completed unsupported probe from incomplete evidence", () => {
    const values = probes();
    values[4] = { ...values[4]!, supported: false };
    expect(capabilityOutcome(values)).toBe("unsupported");
  });

  it("rejects duplicates, unknown probes, and empty exact configurations", () => {
    expect(() => capabilityOutcome([...probes(), probes()[0]!])).toThrow(/duplicate/u);
    expect(() => capabilityOutcome([...probes().slice(1), { id: "other", supported: true, exactConfiguration: "x", detail: "x" }])).toThrow(/unknown/u);
    expect(() => capabilityOutcome(probes().map((value, index) => index === 0 ? { ...value, exactConfiguration: "" } : value))).toThrow(/exact configuration/u);
  });
});
