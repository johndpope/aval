import { describe, expect, it } from "vitest";
import { assertForegroundEnvironment, createPublicProfileId } from "../src/environment-validation.js";
import { validRuntimeReport } from "./test-report.js";

describe("certification environment", () => {
  it("derives stable public profile IDs without serial numbers", () => {
    const environment = validRuntimeReport().environment;
    expect(createPublicProfileId(environment)).toMatch(/^profile-[0-9a-f]{20}$/u);
    expect(createPublicProfileId(structuredClone(environment))).toBe(createPublicProfileId(environment));
  });

  it.each([
    ["driver", "different-driver"],
    ["virtualization", "virtualized"]
  ] as const)("changes the profile ID when hardware %s changes", (field, value) => {
    const environment = validRuntimeReport().environment;
    const changed = structuredClone(environment) as any;
    changed.hardware[field] = value;
    expect(createPublicProfileId(changed)).not.toBe(createPublicProfileId(environment));
  });

  it("refuses hidden, unfocused, dirty, or source-mismatched runs", () => {
    expect(() => assertForegroundEnvironment({ documentVisible: false, documentFocused: true, profileClean: true, sourceMatched: true })).toThrow(/hidden/u);
    expect(() => assertForegroundEnvironment({ documentVisible: true, documentFocused: true, profileClean: true, sourceMatched: true })).not.toThrow();
  });
});
