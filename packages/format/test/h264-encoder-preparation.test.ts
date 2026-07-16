import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import { splitAnnexBAccessUnit } from "../src/h264/annex-b.js";
import { prepareH264EncoderRendition } from "../src/h264/index.js";
import {
  concat,
  makeAccessUnit,
  makeAud,
  makePps,
  makeSps,
  nal
} from "./h264-fixture.js";

const PROFILE = Object.freeze({
  codedWidth: 64,
  codedHeight: 64,
  expectedVisibleRect: Object.freeze([0, 0, 64, 64] as const),
  frameRate: Object.freeze({ numerator: 30, denominator: 1 }),
  requireBt709LimitedRange: true as const
});

// Eight 48x96 yuv420p frames emitted by libx264 r3108. Only the encoder-info
// SEI was removed to keep the checked-in fixture compact; coded NALs are exact.
const REAL_X264_HIGH_B_FRAMES =
  "AAAAAQkQAAAAAWdkAAqs2YzbAWoCAgKAAAADAIAAAB5HiRLNAAAAAWjpeBnLIsAAAAFliIQB//731LfMsu4HIrYLqPdus2Ds53A03ybfoqbhhHgfAAAAAQkwAAABQZokbF/+2qZ00AAAAAEJUAAAAUGeQji/AB8RAAAAAQlQAAABAZ5hNF8AHxAAAAABCVAAAAEBnmNqXwAfEQAAAAEJMAAAAUGaZ0moQWiZTAv//tqmdNEAAAABCVAAAAFBnoUuUTf/AB8RAAAAAQlQAAABAZ6mbl8AHxE=";

describe("H264 encoder preparation", () => {
  it("accepts a real libx264 High-profile closed GOP with B-frame reordering", () => {
    const prepared = prepareH264EncoderRendition({
      profile: {
        codedWidth: 48,
        codedHeight: 96,
        expectedVisibleRect: [0, 0, 48, 96],
        frameRate: { numerator: 30, denominator: 1 },
        requireBt709LimitedRange: true
      },
      units: [{
        id: "unit",
        bytes: new Uint8Array(Buffer.from(REAL_X264_HIGH_B_FRAMES, "base64")),
        expectedAccessUnitCount: 8
      }]
    });
    const unit = prepared.inspection.units[0];

    expect(unit?.accessUnits.map(({ sliceType }) => sliceType))
      .toEqual(["I", "P", "B", "B", "B", "P", "B", "B"]);
    expect(unit?.accessUnits.map(({ pictureOrderCount }) => pictureOrderCount))
      .toEqual([0, 8, 4, 2, 6, 14, 10, 12]);
    expect(unit?.decodeToPresentation).toEqual([0, 4, 2, 1, 3, 7, 5, 6]);
  });

  it("normalizes a High-profile closed GOP and retains decode/presentation order", () => {
    const bytes = reorderedStream();
    const prepared = prepareH264EncoderRendition({
      profile: PROFILE,
      units: [{ id: "unit", bytes, expectedAccessUnitCount: 5 }]
    });

    expect(prepared.units[0]?.accessUnits).toHaveLength(5);
    expect(prepared.inspection.parameterSet.codec).toBe("avc1.640020");
    expect(prepared.inspection.units[0]?.decodeToPresentation)
      .toEqual([0, 4, 2, 1, 3]);
    expect(prepared.inspection.units[0]?.accessUnits.map(({ sliceType }) => sliceType))
      .toEqual(["I", "P", "B", "B", "B"]);
  });

  it("strips bounded encoder SEI and emits canonical four-byte start codes", () => {
    const sps = makeSps();
    const pps = makePps();
    const key = makeAccessUnit({
      idr: true,
      frameNum: 0,
      picOrderCntLsb: 0,
      sps,
      pps,
      aud: makeAud(0)
    });
    const sei = nal(0x06, Uint8Array.of(0x80), 3);
    const bytes = concat(
      makeAud(0),
      sps,
      pps,
      sei,
      key.bytes.slice(makeAud(0).byteLength + sps.byteLength + pps.byteLength)
    );
    const prepared = prepareH264EncoderRendition({
      profile: PROFILE,
      units: [{ id: "unit", bytes, expectedAccessUnitCount: 1 }]
    });
    const canonical = prepared.units[0]?.accessUnits[0]?.bytes;

    expect(canonical).toBeInstanceOf(Uint8Array);
    expect(splitAnnexBAccessUnit(canonical ?? new Uint8Array(), "canonical"))
      .toMatchObject([
        { type: 9, prefixLength: 4 },
        { type: 7, prefixLength: 4 },
        { type: 8, prefixLength: 4 },
        { type: 5, prefixLength: 4 }
      ]);
  });

  it("rejects count mismatches, duplicate unit ids, and unsupported NAL syntax", () => {
    const bytes = reorderedStream();
    expectProfileError(() => prepareH264EncoderRendition({
      profile: PROFILE,
      units: [{ id: "unit", bytes, expectedAccessUnitCount: 4 }]
    }));
    expectProfileError(() => prepareH264EncoderRendition({
      profile: PROFILE,
      units: [
        { id: "unit", bytes, expectedAccessUnitCount: 5 },
        { id: "unit", bytes, expectedAccessUnitCount: 5 }
      ]
    }));
    expectProfileError(() => prepareH264EncoderRendition({
      profile: PROFILE,
      units: [{
        id: "unit",
        bytes: concat(makeAud(0), nal(0x0c, Uint8Array.of(0x80), 4)),
        expectedAccessUnitCount: 1
      }]
    }));
  });
});

function reorderedStream(): Uint8Array {
  const sps = makeSps();
  const pps = makePps();
  return concat(
    makeAccessUnit({ idr: true, frameNum: 0, picOrderCntLsb: 0, sps, pps, aud: makeAud(0) }).bytes,
    makeAccessUnit({ idr: false, frameNum: 1, picOrderCntLsb: 8, aud: makeAud(1) }).bytes,
    makeAccessUnit({ idr: false, frameNum: 2, sliceType: "B", picOrderCntLsb: 4, aud: makeAud(2) }).bytes,
    makeAccessUnit({
      idr: false,
      frameNum: 3,
      sliceType: "B",
      reference: false,
      picOrderCntLsb: 2,
      aud: makeAud(2)
    }).bytes,
    makeAccessUnit({
      idr: false,
      frameNum: 3,
      sliceType: "B",
      reference: false,
      picOrderCntLsb: 6,
      aud: makeAud(2)
    }).bytes
  );
}

function expectProfileError(operation: () => unknown): void {
  expect(operation).toThrow(FormatError);
}
