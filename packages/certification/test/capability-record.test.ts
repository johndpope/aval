import { describe, expect, it } from "vitest";

import {
  capabilityOutcome,
  REQUIRED_ANIMATED_CAPABILITY_PROBES
} from "../src/capability-record.js";

function probes(
  supported = true,
  codecProbe = "av1-exact-config"
) {
  return [...REQUIRED_ANIMATED_CAPABILITY_PROBES, codecProbe].map((id) => ({
    id,
    supported,
    exactConfiguration: `${id}=exact`,
    detail: "probe completed"
  }));
}

describe("animated capability outcome", () => {
  it.each([
    "av1-exact-config",
    "vp9-exact-config",
    "h265-exact-config",
    "h264-exact-config"
  ])("accepts the exact codec-family probe %s", (codecProbe) => {
    expect(capabilityOutcome(probes(true, codecProbe))).toBe("supported");
  });

  it("requires the complete exact prerequisite set before saying supported", () => {
    expect(capabilityOutcome([])).toBe("inconclusive");
    expect(capabilityOutcome(probes().slice(1))).toBe("inconclusive");
    expect(capabilityOutcome(probes().slice(0, -1))).toBe("inconclusive");
  });

  it("distinguishes an unsupported exact config from incomplete evidence", () => {
    const values = probes();
    values[values.length - 1] = { ...values.at(-1)!, supported: false };
    expect(capabilityOutcome(values)).toBe("unsupported");
  });

  it("rejects duplicates, unknown probes, and empty exact configurations", () => {
    expect(() => capabilityOutcome([...probes(), probes()[0]!])).toThrow(/duplicate/u);
    expect(() => capabilityOutcome([
      ...probes().slice(1),
      { id: "other", supported: true, exactConfiguration: "x", detail: "x" }
    ])).toThrow(/unknown/u);
    expect(() => capabilityOutcome(probes().map((value, index, values) =>
      index === values.length - 1
        ? { ...value, exactConfiguration: "" }
        : value
    ))).toThrow(/exact configuration/u);
  });

  it("rejects multiple exact codec probes", () => {
    expect(() => capabilityOutcome([
      ...probes(),
      {
        id: "h264-exact-config",
        supported: true,
        exactConfiguration: "second exact decoder configuration",
        detail: "probe completed"
      }
    ])).toThrow(/multiple exact codec probes/u);
  });
});
