import { FormatError } from "../errors.js";
import {
  H265_MAX_ACCESS_UNIT_BYTES,
  H265_NAL_AUD,
  H265_NAL_EOB,
  H265_NAL_EOS,
  H265_NAL_FILLER,
  H265_NAL_PREFIX_SEI,
  H265_NAL_SUFFIX_SEI,
  isH265RandomAccessNalType,
  isH265VclNalType,
  splitH265AnnexBAccessUnit,
  type H265AnnexBNalUnit
} from "./annex-b.js";
import { requireH265 } from "./failure.js";
import type { H265AccessUnitInput } from "./types.js";

const FOUR_BYTE_START_CODE = Object.freeze([0, 0, 0, 1] as const);

/**
 * Removes encoder metadata and normalizes every retained NAL to a four-byte
 * Annex-B start code. No caller-owned byte view is retained.
 */
export function canonicalizeH265AccessUnit(
  bytes: Uint8Array,
  path = "accessUnit"
): Uint8Array {
  const nals = splitH265AnnexBAccessUnit(bytes, path, {
    allowEncoderMetadata: true
  });
  return canonicalizeNals(nals, path);
}

/** Splits an AUD-delimited raw libx265 stream into canonical access units. */
export function canonicalizeH265EncoderUnitStream(
  bytes: Uint8Array,
  expectedAccessUnitCount: number,
  path = "encoderUnit"
): readonly H265AccessUnitInput[] {
  requireH265(
    Number.isSafeInteger(expectedAccessUnitCount) && expectedAccessUnitCount > 0,
    path,
    "expected access-unit count must be a positive safe integer"
  );
  const maximumNalUnits = expectedAccessUnitCount * 8 + 8;
  requireH265(
    Number.isSafeInteger(maximumNalUnits),
    path,
    "derived NAL-unit budget is not representable"
  );
  const nals = splitH265AnnexBAccessUnit(bytes, path, {
    maximumBytes: H265_MAX_ACCESS_UNIT_BYTES,
    maximumNalUnits,
    allowEncoderMetadata: true
  });
  requireH265(
    nals[0]?.type === H265_NAL_AUD,
    path,
    "raw HEVC encoder stream must begin with AUD"
  );
  const groups: H265AnnexBNalUnit[][] = [];
  let current: H265AnnexBNalUnit[] | undefined;
  for (const nal of nals) {
    if (nal.type === H265_NAL_AUD) {
      if (current !== undefined) groups.push(current);
      current = [nal];
    } else {
      requireH265(current !== undefined, path, "NAL unit appears before the first AUD");
      current.push(nal);
    }
  }
  if (current !== undefined) groups.push(current);
  requireH265(
    groups.length === expectedAccessUnitCount,
    path,
    `expected ${String(expectedAccessUnitCount)} access units but found ${String(groups.length)}`
  );
  return Object.freeze(groups.map((group, index) => {
    const accessUnitPath = `${path}.accessUnits[${String(index)}]`;
    const bytes = canonicalizeNals(group, accessUnitPath);
    const vcl = group.filter((nal) => isH265VclNalType(nal.type));
    requireH265(vcl.length > 0, accessUnitPath, "access unit contains no coded picture");
    return Object.freeze({
      bytes,
      key: vcl.some((nal) => isH265RandomAccessNalType(nal.type))
    });
  }));
}

function canonicalizeNals(
  nals: readonly H265AnnexBNalUnit[],
  path: string
): Uint8Array {
  const retained = nals.filter((nal) => !isMetadataNal(nal.type));
  requireH265(retained.length > 0, path, "canonical access unit is empty");
  requireH265(
    retained[0]?.type === H265_NAL_AUD,
    path,
    "canonical access unit must begin with AUD"
  );
  requireH265(
    retained.some((nal) => isH265VclNalType(nal.type)),
    path,
    "canonical access unit contains no coded picture"
  );
  let length = 0;
  for (const nal of retained) {
    length += FOUR_BYTE_START_CODE.length + nal.payload.length;
    requireH265(
      Number.isSafeInteger(length) && length <= H265_MAX_ACCESS_UNIT_BYTES,
      path,
      "canonical HEVC access unit exceeds the byte budget"
    );
  }
  let output: Uint8Array;
  try {
    output = new Uint8Array(length);
  } catch {
    throw new FormatError(
      "PROFILE_INVALID",
      `HEVC canonicalization allocation of ${String(length)} bytes failed`,
      { path }
    );
  }
  let offset = 0;
  for (const nal of retained) {
    output.set(FOUR_BYTE_START_CODE, offset);
    offset += FOUR_BYTE_START_CODE.length;
    output.set(nal.payload, offset);
    offset += nal.payload.length;
  }
  return output;
}

function isMetadataNal(type: number): boolean {
  return type === H265_NAL_PREFIX_SEI ||
    type === H265_NAL_SUFFIX_SEI ||
    type === H265_NAL_FILLER ||
    type === H265_NAL_EOS ||
    type === H265_NAL_EOB;
}
