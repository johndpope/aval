import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import {
  canonicalizeH265AccessUnit,
  canonicalizeH265EncoderUnitStream,
  splitH265AnnexBAccessUnit
} from "../src/h265/index.js";
import {
  concat,
  h265Nal,
  makeH265AccessUnit,
  makeH265Aud,
  makeH265Pps,
  makeH265Slice,
  makeH265Sps,
  makeH265Vps
} from "./h265-fixture.js";

describe("HEVC Annex-B syntax", () => {
  it("splits canonical NALs and removes emulation prevention", () => {
    const escaped = h265Nal(39, Uint8Array.from([0, 0, 1, 0x80]));
    const nals = splitH265AnnexBAccessUnit(escaped, "sample", {
      allowEncoderMetadata: true
    });

    expect(nals).toHaveLength(1);
    expect(nals[0]).toMatchObject({ type: 39, layerId: 0, temporalId: 0 });
    expect([...nals[0]!.rbsp]).toEqual([0, 0, 1, 0x80]);
  });

  it("strips SEI/filler and normalizes all retained start codes", () => {
    const accessUnit = concat([
      makeH265Aud(0),
      makeH265Vps(),
      makeH265Sps(),
      makeH265Pps(),
      h265Nal(39, Uint8Array.from([0x80]), 3),
      h265Nal(38, Uint8Array.from([0x80]), 3),
      makeH265Slice({ nalType: 20, sliceType: "I" })
    ]);
    const canonical = canonicalizeH265AccessUnit(accessUnit);
    const nals = splitH265AnnexBAccessUnit(canonical);

    expect(nals.map((nal) => nal.type)).toEqual([35, 32, 33, 34, 20]);
    expect(nals.every((nal) => nal.prefixLength === 4)).toBe(true);
  });

  it("splits an AUD-delimited encoder stream and derives key assertions", () => {
    const key = makeH265AccessUnit({
      vps: makeH265Vps(),
      sps: makeH265Sps(),
      pps: makeH265Pps(),
      metadata: [h265Nal(39, Uint8Array.from([0x80]))],
      slice: { nalType: 20, sliceType: "I" }
    });
    const delta = makeH265AccessUnit({
      slice: { nalType: 1, sliceType: "P", poc: 1, negativeReferences: [-1] }
    });

    const result = canonicalizeH265EncoderUnitStream(
      concat([key.bytes, delta.bytes]),
      2
    );
    expect(result.map((accessUnit) => accessUnit.key)).toEqual([true, false]);
    expect(
      splitH265AnnexBAccessUnit(result[0]!.bytes).map((nal) => nal.type)
    ).toEqual([35, 32, 33, 34, 20]);
  });

  it.each([
    ["missing start code", Uint8Array.from([1, 2, 3, 4, 5, 6])],
    ["overlong start code", Uint8Array.from([0, 0, 0, 0, 1, 0x46, 1, 0x80])],
    ["forbidden bit", Uint8Array.from([0, 0, 0, 1, 0xc6, 1, 0x80])],
    ["zero temporal id", Uint8Array.from([0, 0, 0, 1, 0x46, 0, 0x80])],
    ["multilayer", Uint8Array.from([0, 0, 0, 1, 0x47, 1, 0x80])],
    ["truncated header", Uint8Array.from([0, 0, 0, 1, 0x46, 1])],
    ["bad emulation prevention", Uint8Array.from([0, 0, 0, 1, 0x4e, 1, 0, 0, 3, 4])]
  ])("rejects %s", (_label, bytes) => {
    expect(() => splitH265AnnexBAccessUnit(bytes, "sample", {
      allowEncoderMetadata: true
    })).toThrow(FormatError);
  });

  it("enforces byte and NAL-count budgets", () => {
    const bytes = concat([makeH265Aud(0), h265Nal(20, Uint8Array.from([0x80]))]);
    expect(() => splitH265AnnexBAccessUnit(bytes, "sample", {
      maximumBytes: bytes.length - 1
    })).toThrow(FormatError);
    expect(() => splitH265AnnexBAccessUnit(bytes, "sample", {
      maximumNalUnits: 1
    })).toThrow(FormatError);
  });
});
