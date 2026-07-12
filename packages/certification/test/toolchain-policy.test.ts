import { describe, expect, it } from "vitest";

import { validateCandidateToolchain } from "../src/toolchain-policy.js";

const policy = Object.freeze({
  minimumNode: "22.12.0",
  minimumNpm: "10.9.0",
  candidateNode: "22.12.0",
  candidateNpm: "10.9.0",
  typescript: "7.0.2",
  vitest: "4.1.10",
  playwright: "1.61.1",
  apiExtractor: "7.58.9"
});
const exact = Object.freeze({
  node: "22.12.0",
  npm: "10.9.0",
  typescript: "7.0.2",
  vitest: "4.1.10",
  playwright: "1.61.1",
  apiExtractor: "7.58.9"
});

describe("candidate toolchain policy", () => {
  it("captures the exact reproducible candidate toolchain independently of engine minima", () => {
    expect(validateCandidateToolchain(policy, exact)).toEqual(exact);
    expect(() => validateCandidateToolchain(policy, { ...exact, node: "22.13.0" })).toThrow(/candidate pin/u);
  });

  it("rejects tools below the package/candidate floor before exact-pin comparison", () => {
    expect(() => validateCandidateToolchain(policy, { ...exact, node: "22.11.9" })).toThrow(/below package engine minimum/u);
    expect(() => validateCandidateToolchain(policy, { ...exact, npm: "10.8.9" })).toThrow(/below candidate minimum/u);
  });

  it("rejects browser digests in the semantic-version capture instead of parsing them as versions", () => {
    expect(() => validateCandidateToolchain(policy, { ...exact, playwrightBrowserManifestSha256: "a".repeat(64) } as any)).toThrow(/unknown field/u);
  });
});
