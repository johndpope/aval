import { describe, expect, it } from "vitest";
import { evaluateNamedProfileMatrix, type NamedProfileIndexInput } from "../src/report-index-criteria.js";

const policy = {
  requiredPlatformClasses: ["mac", "windows"],
  requiredBrowsersByPlatform: { mac: ["Safari", "Chrome"], windows: ["Chrome", "Edge"] },
  requiredRefreshMilliHz: [60_000],
  conditionalRefreshMilliHz: 120_000
} as const;

function profile(platformClass: string, browserProduct: string, refreshMilliHz: number, animationSupported = true): NamedProfileIndexInput {
  return {
    profileId: `${platformClass}-${browserProduct}-${String(refreshMilliHz)}`.toLowerCase(),
    platformClass, browserProduct, refreshMilliHz, refresh120Available: false,
    animationSupported,
    runtimeScheduling: animationSupported ? "passed" : "unsupported",
    staticFallback: "passed"
  };
}

describe("named certification matrix", () => {
  it("passes only complete declared slots with at least one animated pass per platform", () => {
    const profiles = [profile("mac", "Safari", 60_000), profile("mac", "Chrome", 60_000, false), profile("windows", "Chrome", 60_000), profile("windows", "Edge", 60_000, false)];
    expect(evaluateNamedProfileMatrix(profiles, policy)).toMatchObject({ status: "passed", failures: [], missingSlots: [] });
  });

  it("blocks a supported failure even when another profile passes", () => {
    const failed = { ...profile("mac", "Chrome", 60_000), runtimeScheduling: "failed" as const };
    const profiles = [profile("mac", "Safari", 60_000), failed, profile("windows", "Chrome", 60_000), profile("windows", "Edge", 60_000, false)];
    expect(evaluateNamedProfileMatrix(profiles, policy)).toMatchObject({ status: "failed", failures: expect.arrayContaining([expect.stringContaining("supported-runtime")]) });
  });

  it("requires 120 Hz slots whenever the platform records that mode as available", () => {
    const profiles = [{ ...profile("mac", "Safari", 60_000), refresh120Available: true }, { ...profile("mac", "Chrome", 60_000, false), refresh120Available: true }, profile("windows", "Chrome", 60_000), profile("windows", "Edge", 60_000, false)];
    const result = evaluateNamedProfileMatrix(profiles, policy);
    expect(result.status).toBe("inconclusive");
    expect(result.missingSlots).toEqual(expect.arrayContaining(["mac/Safari/120000", "mac/Chrome/120000"]));
  });

  it("rejects duplicate and undeclared matrix slots", () => {
    const duplicate = profile("mac", "Safari", 60_000);
    const result = evaluateNamedProfileMatrix([duplicate, duplicate, profile("linux", "Chrome", 60_000)], policy);
    expect(result.status).toBe("failed");
    expect(result.failures.join("\n")).toMatch(/duplicate-slot|unknown-platform/u);
  });

  it("rejects undeclared refresh rates and incoherent conditional availability", () => {
    const unknown = profile("mac", "Safari", 75_000);
    expect(evaluateNamedProfileMatrix([unknown], policy).failures).toContain(`unknown-refresh:${unknown.profileId}:75000`);
    const incoherent = [{ ...profile("mac", "Safari", 60_000), refresh120Available: true }, profile("mac", "Chrome", 60_000)];
    expect(evaluateNamedProfileMatrix(incoherent, policy).failures).toContain("incoherent-conditional-refresh:mac");
    const unproven120 = profile("mac", "Safari", 120_000);
    expect(evaluateNamedProfileMatrix([unproven120], policy).failures).toContain(`conditional-refresh-without-availability:${unproven120.profileId}`);
  });
});
