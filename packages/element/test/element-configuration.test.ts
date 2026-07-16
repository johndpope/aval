import { describe, expect, it } from "vitest";

import {
  diffElementConfiguration,
  normalizeAutoplay,
  normalizeBindings,
  normalizeCrossOrigin,
  normalizeFit,
  normalizeIntegrity,
  normalizeInteractionFor,
  normalizeMotion,
  normalizeSize,
  normalizeSource,
  normalizeState,
  readElementConfiguration
} from "../src/element-configuration.js";

describe("element configuration", () => {
  it("normalizes the exact declarative defaults", () => {
    const read = readElementConfiguration(() => null);
    expect(read.configuration).toEqual({
      sourceCandidates: [],
      crossOrigin: "anonymous",
      motion: "auto",
      autoplay: "visible",
      fit: null,
      bindings: "auto",
      state: null,
      interactionFor: "",
      width: null,
      height: null
    });
    expect(read.failures).toEqual([]);
  });

  it("keeps retrieval identity limited to ordered source snapshots and credentials", () => {
    const first = readElementConfiguration(
      (name) => name === "state" ? "idle" : null,
      sourceRead("/a.avl", "avc1.640028")
    ).configuration;
    const stateOnly = Object.freeze({ ...first, state: "active" });
    expect(diffElementConfiguration(first, stateOnly)).toMatchObject({
      retrievalIdentity: false,
      state: true
    });
    expect(diffElementConfiguration(first, Object.freeze({
      ...first,
      crossOrigin: "use-credentials" as const
    })).retrievalIdentity).toBe(true);
    expect(diffElementConfiguration(first, Object.freeze({
      ...first,
      sourceCandidates: sourceRead("/b.avl", "avc1.640028").candidates
    })).retrievalIdentity).toBe(true);
  });

  it("enforces every closed property and bound", () => {
    expect(normalizeMotion("reduce")).toBe("reduce");
    expect(normalizeAutoplay("manual")).toBe("manual");
    expect(normalizeBindings("none")).toBe("none");
    expect(normalizeCrossOrigin("use-credentials")).toBe("use-credentials");
    expect(normalizeFit("cover")).toBe("cover");
    expect(normalizeFit(null)).toBeNull();
    expect(normalizeState("custom.success")).toBe("custom.success");
    expect(normalizeSize(Number.MAX_SAFE_INTEGER)).toBe(Number.MAX_SAFE_INTEGER);
    expect(normalizeSource("x".repeat(4_096))).toHaveLength(4_096);
    expect(normalizeInteractionFor("x".repeat(256))).toHaveLength(256);
    expect(normalizeIntegrity("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
      .toMatch(/^sha256-/u);
    for (const invalid of ["system", "none", true, null]) {
      expect(() => normalizeMotion(invalid)).toThrow();
    }
    expect(() => normalizeState("Hovered State")).toThrow();
    expect(() => normalizeSize(0)).toThrow();
    expect(() => normalizeSize(Number.MAX_SAFE_INTEGER + 1)).toThrow();
    expect(() => normalizeSource("")).toThrow();
    expect(() => normalizeIntegrity("")).toThrow();
    expect(() => normalizeSource("x".repeat(4_097))).toThrow();
    expect(() => normalizeInteractionFor("x".repeat(257))).toThrow();
  });

  it("accepts safe-integer size hints above the former element cap", () => {
    const read = readElementConfiguration((name) => ({
      width: "1048576",
      height: String(Number.MAX_SAFE_INTEGER)
    } as Record<string, string>)[name] ?? null);

    expect(read.configuration).toMatchObject({
      width: 1_048_576,
      height: Number.MAX_SAFE_INTEGER
    });
    expect(read.failures).toEqual([]);

    const padded = readElementConfiguration((name) =>
      name === "width" ? "000000000000000001048576" : null
    );
    expect(padded.configuration.width).toBe(1_048_576);
    expect(padded.failures).toEqual([]);
  });

  it("defaults hostile attributes and records bounded failures", () => {
    const values: Record<string, string> = {
      motion: "maybe",
      crossorigin: "credentialed",
      width: "1.5",
      state: "<script>"
    };
    const read = readElementConfiguration((name) => values[name] ?? null);
    expect(read.configuration).toMatchObject({
      motion: "auto",
      crossOrigin: "anonymous",
      width: null,
      state: null
    });
    expect(read.failures.map(({ attribute }) => attribute)).toEqual([
      "crossorigin",
      "motion",
      "state",
      "width"
    ]);
  });

  it("publishes frozen source snapshots and source-local failure identities", () => {
    const mutableCandidate = {
      src: "/a.avl",
      type: 'application/vnd.aval; codecs="avc1.640028"' as const,
      codec: "avc1.640028",
      integrity: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    };
    const read = readElementConfiguration(() => null, {
      candidates: [mutableCandidate],
      failures: [
        { sourceIndex: 1, attribute: "type", code: "invalid-configuration" }
      ]
    });

    mutableCandidate.src = "/mutated.avl";
    expect(read.configuration.sourceCandidates[0]?.src).toBe("/a.avl");
    expect(Object.isFrozen(read.configuration.sourceCandidates)).toBe(true);
    expect(Object.isFrozen(read.configuration.sourceCandidates[0])).toBe(true);
    expect(read.failures).toEqual([{
      attribute: "source[1].type",
      code: "invalid-configuration"
    }]);
  });

  it("rejects huge host scalar attributes without numeric conversion", () => {
    const huge = "9".repeat(1_048_576);
    const read = readElementConfiguration((name) => ({
      motion: huge,
      width: huge
    } as Record<string, string>)[name] ?? null);
    expect(read.configuration).toMatchObject({
      motion: "auto",
      width: null
    });
    expect(read.failures.map(({ attribute }) => attribute)).toEqual([
      "motion",
      "width"
    ]);
  });
});

function sourceRead(src: string, codec: string) {
  return Object.freeze({
    candidates: Object.freeze([Object.freeze({
      src,
      type: `application/vnd.aval; codecs="${codec}"` as const,
      codec,
      integrity: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    })]),
    failures: Object.freeze([])
  });
}
