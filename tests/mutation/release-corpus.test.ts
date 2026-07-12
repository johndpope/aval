import { describe, expect, it } from "vitest";
import { canonicalJson } from "../../packages/certification/src/canonical-json.js";
import { validateRuntimeReport } from "../../packages/certification/src/schema-validation.js";
import { validRuntimeReport } from "../../packages/certification/test/test-report.js";
import { RELEASE_INTEGER_LIMITS, boundaryValues, createSeededGenerator, mutateOneField } from "./release-corpus.js";
import { mutationSeeds } from "./seed-profile.js";

const SEEDS = mutationSeeds([1, 0x7f4a7c15, 0xa11ce5ed, 0xffff_ffff]);

describe("bounded release mutation corpus", () => {
  it.each(SEEDS)("covers below/at/above and 1,000 bounded values for seed %d", (seed) => {
    const generator = createSeededGenerator(seed);
    for (const limit of RELEASE_INTEGER_LIMITS) {
      const values = boundaryValues(limit, 1_000, generator);
      expect(values).toHaveLength(1_000);
      expect(values.slice(0, 3)).toEqual([limit - 1, limit, limit === Number.MAX_SAFE_INTEGER ? limit : limit + 1]);
      expect(values.every(Number.isSafeInteger)).toBe(true);
    }
  });

  it("mutates report trust boundaries one at a time with stable path-free errors", () => {
    const report = validRuntimeReport();
    const mutations = [
      mutateOneField(report, ["candidateManifestDigest"], "0"),
      mutateOneField(report, ["attachments", 0, "byteLength"], -1),
      mutateOneField(report, ["scenarios", 0, "ledgerDigest"], "f"),
      mutateOneField(report, ["environment", "browser", "version"], "latest")
    ];
    for (const mutation of mutations) {
      expect(() => validateRuntimeReport(mutation)).toThrow();
      expect(() => canonicalJson(mutation)).not.toThrow();
    }
  });
});
