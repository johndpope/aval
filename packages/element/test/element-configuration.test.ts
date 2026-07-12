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
      src: "",
      integrity: "",
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

  it("keeps retrieval identity limited to src, integrity, and credentials", () => {
    const first = readElementConfiguration((name) => ({
      src: "/a.rma",
      state: "idle"
    } as Record<string, string>)[name] ?? null).configuration;
    const stateOnly = Object.freeze({ ...first, state: "active" });
    expect(diffElementConfiguration(first, stateOnly)).toMatchObject({
      retrievalIdentity: false,
      state: true
    });
    expect(diffElementConfiguration(first, Object.freeze({
      ...first,
      crossOrigin: "use-credentials" as const
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
    expect(normalizeSize(16_384)).toBe(16_384);
    expect(normalizeSource("x".repeat(4_096))).toHaveLength(4_096);
    expect(normalizeInteractionFor("x".repeat(256))).toHaveLength(256);
    expect(normalizeIntegrity("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
      .toMatch(/^sha256-/u);
    for (const invalid of ["system", "none", true, null]) {
      expect(() => normalizeMotion(invalid)).toThrow();
    }
    expect(() => normalizeState("Hovered State")).toThrow();
    expect(() => normalizeSize(0)).toThrow();
    expect(() => normalizeSize(16_385)).toThrow();
    expect(() => normalizeSource("x".repeat(4_097))).toThrow();
    expect(() => normalizeInteractionFor("x".repeat(257))).toThrow();
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

  it("rejects huge scalar attributes before regex or set work", () => {
    const huge = "9".repeat(1_048_576);
    const read = readElementConfiguration((name) => ({
      integrity: huge,
      motion: huge,
      width: huge
    } as Record<string, string>)[name] ?? null);
    expect(read.configuration).toMatchObject({
      integrity: "",
      motion: "auto",
      width: null
    });
    expect(read.failures.map(({ attribute }) => attribute)).toEqual([
      "integrity",
      "motion",
      "width"
    ]);
  });
});
