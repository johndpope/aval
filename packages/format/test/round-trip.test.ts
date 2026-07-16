import { describe, expect, it } from "vitest";

import { parseFrontIndex, validateCompleteAsset } from "../src/parser.js";
import { writeCanonicalAsset } from "../src/writer.js";
import {
  byteIdentity,
  shuffledWriterInput,
  twoRenditionWriterInput,
  writerInputFromParsed
} from "./writer-fixture.js";

describe("canonical writer/parser round trip", () => {
  it("reconstructs writer input from parsed metadata and caller payloads byte-identically", () => {
    const callerInput = shuffledWriterInput(twoRenditionWriterInput());
    const first = writeCanonicalAsset(callerInput);
    const parsed = parseFrontIndex(first);
    const reconstructed = writerInputFromParsed(parsed, callerInput);
    const second = writeCanonicalAsset(reconstructed);

    expect(byteIdentity(first, second)).toBe(true);
    expect(validateCompleteAsset({ bytes: second, frontIndex: parsed }).fileRange).toEqual({
      offset: 0,
      length: second.byteLength
    });
  });

  it("preserves every derived chunk span and payload byte range", () => {
    const input = twoRenditionWriterInput();
    const bytes = writeCanonicalAsset(input);
    const parsed = parseFrontIndex(bytes);

    expect(parsed.records).toHaveLength(input.chunks.length);
    for (let index = 0; index < parsed.records.length; index += 1) {
      const record = parsed.records[index]!;
      expect(Array.from(bytes.subarray(
        record.byteOffset,
        record.byteOffset + record.byteLength
      ))).toEqual(Array.from(input.chunks[index]!.bytes));
    }
    parsed.manifest.units.forEach((unit, unitIndex) => {
      unit.chunks.forEach((span, renditionIndex) => {
        const previousRenditions = parsed.manifest.units.reduce(
          (sum, candidate) => sum + candidate.chunks
            .slice(0, renditionIndex)
            .reduce((inner, candidateSpan) => inner + candidateSpan.chunkCount, 0),
          0
        );
        const prefix = parsed.manifest.units
          .slice(0, unitIndex)
          .reduce((sum, candidate) => sum + candidate.chunks[renditionIndex]!.chunkCount, 0);
        expect(span.chunkStart).toBe(previousRenditions + prefix);
        expect(span.frameCount).toBe(unit.frameCount);
      });
    });
  });
});
