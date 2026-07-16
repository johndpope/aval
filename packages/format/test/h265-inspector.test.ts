import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import {
  canonicalizeH265AccessUnit,
  inspectH265AnnexBRendition
} from "../src/h265/index.js";
import {
  h265Nal,
  makeH265AccessUnit,
  makeH265Pps,
  makeH265Sps,
  makeH265Unit,
  makeH265Vps,
  validH265InspectionInput
} from "./h265-fixture.js";

describe("HEVC rendition inspector", () => {
  it("derives decode and presentation order for closed I/P/B units", () => {
    const inspection = inspectH265AnnexBRendition(validH265InspectionInput());

    expect(inspection.parameterSet).toMatchObject({
      codec: "hvc1.1.6.L30.90",
      codedWidth: 64,
      codedHeight: 64,
      bitDepth: 8,
      maxNumReorderPics: 2
    });
    expect(inspection.units[0]?.decodeToPresentation).toEqual([0, 4, 2, 1, 3, 5]);
    expect(inspection.units[0]?.accessUnits.map((accessUnit) => ({
      decode: accessUnit.decodeIndex,
      presentation: accessUnit.presentationIndex,
      poc: accessUnit.pictureOrderCount,
      type: accessUnit.sliceType,
      refs: accessUnit.referencedPictureOrderCounts
    }))).toEqual([
      { decode: 0, presentation: 0, poc: 0, type: "I", refs: [] },
      { decode: 1, presentation: 4, poc: 4, type: "P", refs: [0] },
      { decode: 2, presentation: 2, poc: 2, type: "B", refs: [0, 4] },
      { decode: 3, presentation: 1, poc: 1, type: "B", refs: [0, 2] },
      { decode: 4, presentation: 3, poc: 3, type: "B", refs: [2, 4] },
      { decode: 5, presentation: 5, poc: 5, type: "P", refs: [4] }
    ]);
    expect(Object.isFrozen(inspection)).toBe(true);
    expect(Object.isFrozen(inspection.units[0]?.accessUnits)).toBe(true);
  });

  it("accepts stable parameter sets repeated by independent units", () => {
    const inspection = inspectH265AnnexBRendition(
      validH265InspectionInput([makeH265Unit("idle"), makeH265Unit("hover")])
    );
    expect(inspection.units.map((unit) => unit.id)).toEqual(["idle", "hover"]);
  });

  it("accepts CRA only as a closed unit start", () => {
    const unit = {
      id: "idle",
      accessUnits: [makeH265AccessUnit({
        vps: makeH265Vps(),
        sps: makeH265Sps({ maxReorder: 0, maxBufferMinus1: 0 }),
        pps: makeH265Pps(),
        slice: {
          nalType: 21,
          sliceType: "I",
          poc: 0,
          noOutputOfPriorPictures: true
        }
      })]
    };
    expect(
      inspectH265AnnexBRendition(validH265InspectionInput([unit]))
        .units[0]?.accessUnits[0]?.randomAccess
    ).toBe("cra");
  });

  it("rejects a cross-unit or forward-unknown reference", () => {
    const unit = makeH265Unit();
    const bad = {
      ...unit,
      accessUnits: [
        unit.accessUnits[0]!,
        makeH265AccessUnit({
          slice: { nalType: 1, sliceType: "P", poc: 1, negativeReferences: [-2] }
        })
      ]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([bad])))
      .toThrow(/outside this independently decoded unit/);
  });

  it("rejects POC gaps, duplicate POC, and excess reordering", () => {
    const base = makeH265Unit();
    const gap = {
      ...base,
      accessUnits: [...base.accessUnits.slice(0, 4), base.accessUnits[5]!]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([gap])))
      .toThrow(/contiguous/);

    const duplicate = {
      ...base,
      accessUnits: [base.accessUnits[0]!, base.accessUnits[1]!, base.accessUnits[1]!]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([duplicate])))
      .toThrow(/duplicate picture-order/);

    const lowReorderKey = makeH265AccessUnit({
      vps: makeH265Vps(),
      sps: makeH265Sps({ maxReorder: 0 }),
      pps: makeH265Pps(),
      slice: { nalType: 20, sliceType: "I" }
    });
    const lowReorder = {
      ...base,
      accessUnits: [lowReorderKey, ...base.accessUnits.slice(1)]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([lowReorder])))
      .toThrow(/reordering exceeds/);
  });

  it("rejects false key assertions and non-canonical stored start codes", () => {
    const unit = makeH265Unit();
    const falseKey = {
      ...unit,
      accessUnits: [{ ...unit.accessUnits[0]!, key: false }, ...unit.accessUnits.slice(1)]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([falseKey])))
      .toThrow(/key assertion/);

    const first = makeH265AccessUnit({
      vps: makeH265Vps(),
      sps: makeH265Sps(),
      pps: makeH265Pps(),
      prefixLength: 3,
      slice: { nalType: 20, sliceType: "I" }
    });
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([
      { id: "idle", accessUnits: [first] }
    ]))).toThrow(/four-byte start codes/);
  });

  it("requires exact stable parameter-set bytes and profile declarations", () => {
    const changedBase = makeH265Unit("hover");
    const changed = {
      ...changedBase,
      accessUnits: [
        makeH265AccessUnit({
          vps: makeH265Vps({ levelIdc: 60 }),
          sps: makeH265Sps({ ptl: { levelIdc: 60 } }),
          pps: makeH265Pps(),
          slice: { nalType: 20, sliceType: "I" }
        }),
        ...changedBase.accessUnits.slice(1)
      ]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([
      makeH265Unit("idle"),
      changed
    ]))).toThrow(/parameter-set bytes changed/);

    const validDimensions = validH265InspectionInput();
    const dimensions = {
      ...validDimensions,
      profile: { ...validDimensions.profile, codedWidth: 66 }
    };
    expect(() => inspectH265AnnexBRendition(dimensions)).toThrow(FormatError);

    const colorBase = makeH265Unit();
    const colorUnit = {
      ...colorBase,
      accessUnits: [
        makeH265AccessUnit({
          vps: makeH265Vps(),
          sps: makeH265Sps({ fullRange: true }),
          pps: makeH265Pps(),
          slice: { nalType: 20, sliceType: "I" }
        }),
        ...colorBase.accessUnits.slice(1)
      ]
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([colorUnit])))
      .toThrow(/BT.709 limited-range/);
  });

  it("removes encoder metadata before strict inspection", () => {
    const first = makeH265AccessUnit({
      vps: makeH265Vps(),
      sps: makeH265Sps(),
      pps: makeH265Pps(),
      metadata: [h265Nal(39, Uint8Array.from([0x80]))],
      slice: { nalType: 20, sliceType: "I" }
    });
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([
      { id: "idle", accessUnits: [first] }
    ]))).toThrow(FormatError);

    const canonical = { ...first, bytes: canonicalizeH265AccessUnit(first.bytes) };
    expect(
      inspectH265AnnexBRendition(validH265InspectionInput([
        { id: "idle", accessUnits: [canonical] }
      ])).units[0]?.accessUnits[0]?.key
    ).toBe(true);
  });

  it("rejects truncated slice dependency syntax", () => {
    const key = makeH265Unit().accessUnits[0]!;
    const fullDelta = makeH265AccessUnit({
      slice: {
        nalType: 1,
        sliceType: "P",
        poc: 1,
        negativeReferences: [-1],
        opaqueBytes: 0
      }
    });
    const truncatedDelta = {
      ...fullDelta,
      bytes: fullDelta.bytes.slice(0, -2)
    };
    expect(() => inspectH265AnnexBRendition(validH265InspectionInput([
      { id: "idle", accessUnits: [key, truncatedDelta] }
    ]))).toThrow(FormatError);
  });
});
