import { describe, expect, it } from "vitest";
import { canonicalJson } from "../src/canonical-json.js";

describe("canonicalJson", () => {
  it("sorts every object while preserving array order and one final newline", () => {
    const left = canonicalJson({ z: 1, a: { z: true, a: [3, 2, 1] } });
    const right = canonicalJson({ a: { a: [3, 2, 1], z: true }, z: 1 });
    expect(left).toBe('{"a":{"a":[3,2,1],"z":true},"z":1}\n');
    expect(right).toBe(left);
  });

  it.each([Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1, undefined, 1n])(
    "rejects unsupported value %s",
    (value) => expect(() => canonicalJson({ value })).toThrow()
  );

  it("rejects cycles, non-plain objects, forbidden keys, and unpaired surrogates", () => {
    const cyclic: { self?: unknown } = {};
    cyclic.self = cyclic;
    expect(() => canonicalJson(cyclic)).toThrow(/cyclic/u);
    expect(() => canonicalJson(new Date())).toThrow(/plain prototype/u);
    expect(() => canonicalJson(JSON.parse('{"__proto__":1}') as unknown)).toThrow(/forbidden/u);
    expect(() => canonicalJson("\ud800")).toThrow(/unpaired/u);
  });

  it("enforces structural limits before producing unbounded output", () => {
    expect(() => canonicalJson([1, 2], { maxDepth: 8, maxNodes: 2, maxStringLength: 8, maxBytes: 16 })).toThrow(/node limit/u);
    expect(() => canonicalJson("123456789", { maxDepth: 8, maxNodes: 8, maxStringLength: 8, maxBytes: 64 })).toThrow(/string limit/u);
  });
});
