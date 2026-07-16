import { describe, expect, it } from "vitest";

import {
  createCanonicalChunkPlan,
  validateCanonicalChunkSpans
} from "../src/chunk-plan.js";
import { FormatError } from "../src/errors.js";
import type { ProductionRendition, Unit } from "../src/model.js";

const renditions = [{ id: "high" }, { id: "low" }] as ProductionRendition[];
const units = [
  {
    id: "a",
    frameCount: 2,
    chunks: [
      { rendition: "high", chunkStart: 0, chunkCount: 3, frameCount: 2, sha256: "0".repeat(64) },
      { rendition: "low", chunkStart: 5, chunkCount: 2, frameCount: 2, sha256: "0".repeat(64) }
    ]
  },
  {
    id: "b",
    frameCount: 1,
    chunks: [
      { rendition: "high", chunkStart: 3, chunkCount: 2, frameCount: 1, sha256: "0".repeat(64) },
      { rendition: "low", chunkStart: 7, chunkCount: 1, frameCount: 1, sha256: "0".repeat(64) }
    ]
  }
] as unknown as Unit[];

describe("canonical chunk plan", () => {
  it("owns rendition, unit, and decoder-submission traversal", () => {
    const plan = createCanonicalChunkPlan(renditions, units, 100, 100);
    expect(plan.recordCount).toBe(8);
    expect(plan.spans.map(({ renditionId, unitId, chunkStart, chunkCount }) =>
      [renditionId, unitId, chunkStart, chunkCount]
    )).toEqual([
      ["high", "a", 0, 3],
      ["high", "b", 3, 2],
      ["low", "a", 5, 2],
      ["low", "b", 7, 1]
    ]);
    expect([...plan.records()].map(({ decodeIndex }) => decodeIndex)).toEqual([
      0, 1, 2, 0, 1, 0, 1, 0
    ]);
    expect([...plan.records()].filter(({ randomAccessRequired }) => randomAccessRequired))
      .toHaveLength(4);
    expect(plan.recordAt(4)).toMatchObject({ renditionId: "high", unitId: "b", decodeIndex: 1 });
    validateCanonicalChunkSpans(plan, units);
  });

  it("rejects noncanonical span starts, cross-rendition order, and frame mismatch", () => {
    for (const malformed of [
      [{ ...units[0]!, chunks: [{ ...units[0]!.chunks[0]!, chunkStart: 1 }, units[0]!.chunks[1]!] }, units[1]!],
      [{ ...units[0]!, chunks: [{ ...units[0]!.chunks[0]!, rendition: "low" }, units[0]!.chunks[1]!] }, units[1]!],
      [{ ...units[0]!, chunks: [{ ...units[0]!.chunks[0]!, frameCount: 1 }, units[0]!.chunks[1]!] }, units[1]!]
    ]) {
      expect(() => createCanonicalChunkPlan(renditions, malformed as Unit[], 100, 100))
        .toThrowError(FormatError);
    }
  });

  it("enforces chunk and frame budgets independently", () => {
    expect(() => createCanonicalChunkPlan(renditions, units, 7, 100))
      .toThrowError(expect.objectContaining({ code: "BUDGET_EXCEEDED" }));
    expect(() => createCanonicalChunkPlan(renditions, units, 100, 2))
      .toThrowError(expect.objectContaining({ code: "BUDGET_EXCEEDED" }));
  });
});
