import { h264Invalid, requireH264 } from "./failure.js";

export const H264_NAL_TYPE_NON_IDR = 1;
export const H264_NAL_TYPE_IDR = 5;
export const H264_NAL_TYPE_SEI = 6;
export const H264_NAL_TYPE_SPS = 7;
export const H264_NAL_TYPE_PPS = 8;
export const H264_NAL_TYPE_AUD = 9;

const ALLOWED_NAL_TYPES: ReadonlySet<number> = new Set([
  H264_NAL_TYPE_NON_IDR,
  H264_NAL_TYPE_IDR,
  H264_NAL_TYPE_SPS,
  H264_NAL_TYPE_PPS,
  H264_NAL_TYPE_AUD
]);
const DEFAULT_MAX_NAL_UNITS = 5_124;

export interface AnnexBNalUnit {
  readonly type: number;
  readonly referenceIdc: number;
  readonly offset: number;
  readonly prefixLength: 3 | 4;
  readonly payload: Uint8Array;
  readonly rbsp: Uint8Array;
}

interface StartCode {
  readonly offset: number;
  readonly length: 3 | 4;
}

export function splitAnnexBAccessUnit(
  bytes: Uint8Array,
  path: string,
  maximumNalUnits = DEFAULT_MAX_NAL_UNITS,
  allowEncoderSei = false
): readonly AnnexBNalUnit[] {
  requireH264(bytes instanceof Uint8Array, path, "access unit must be bytes");
  requireH264(bytes.length >= 5, path, "Annex B access unit is too short");

  requireH264(
    Number.isSafeInteger(maximumNalUnits) && maximumNalUnits > 0,
    path,
    "NAL-unit budget is invalid"
  );
  const starts = findStartCodes(bytes, path, maximumNalUnits);
  requireH264(starts.length > 0, path, "Annex B start code is missing", 0);
  requireH264(starts[0]?.offset === 0, path, "bytes precede the first start code", 0);

  const units = starts.map((start, index) => {
    const payloadOffset = start.offset + start.length;
    const payloadEnd = starts[index + 1]?.offset ?? bytes.length;
    requireH264(
      payloadEnd > payloadOffset,
      path,
      "empty NAL unit is forbidden",
      start.offset
    );
    const payload = bytes.subarray(payloadOffset, payloadEnd);
    const header = payload[0];
    requireH264(header !== undefined, path, "NAL header is missing", payloadOffset);
    requireH264(
      payload[payload.length - 1] !== 0,
      path,
      "NAL units may not contain trailing_zero_8bits",
      payloadEnd - 1
    );
    requireH264(
      (header & 0x80) === 0,
      path,
      "forbidden_zero_bit must be zero",
      payloadOffset
    );
    const type = header & 0x1f;
    requireH264(
      ALLOWED_NAL_TYPES.has(type) ||
        (allowEncoderSei && type === H264_NAL_TYPE_SEI),
      path,
      `NAL unit type ${String(type)} is not permitted by the production H264 profile`,
      payloadOffset
    );
    const referenceIdc = (header >> 5) & 0x03;
    if (type === H264_NAL_TYPE_AUD || type === H264_NAL_TYPE_SEI) {
      requireH264(
        referenceIdc === 0,
        path,
        "AUD and SEI nal_ref_idc must be zero",
        payloadOffset
      );
    } else if (
      type === H264_NAL_TYPE_SPS ||
      type === H264_NAL_TYPE_PPS ||
      type === H264_NAL_TYPE_IDR
    ) {
      requireH264(
        referenceIdc !== 0,
        path,
        "parameter sets and IDR pictures must be reference NAL units",
        payloadOffset
      );
    }
    return Object.freeze({
      type,
      referenceIdc,
      offset: payloadOffset,
      prefixLength: start.length,
      payload,
      rbsp: removeEmulationPrevention(payload.subarray(1), path, payloadOffset + 1)
    });
  });

  return Object.freeze(units);
}

function findStartCodes(
  bytes: Uint8Array,
  path: string,
  maximumNalUnits: number
): readonly StartCode[] {
  const starts: StartCode[] = [];
  let cursor = 0;
  while (cursor < bytes.length) {
    if (bytes[cursor] !== 0) {
      cursor += 1;
      continue;
    }
    const runStart = cursor;
    while (cursor < bytes.length && bytes[cursor] === 0) {
      cursor += 1;
    }
    if (bytes[cursor] !== 1 || cursor - runStart < 2) {
      continue;
    }
    const zeroCount = cursor - runStart;
    if (zeroCount > 3) {
      h264Invalid(path, "start codes may contain only two or three zero bytes", runStart);
    }
    starts.push(
      Object.freeze({
        offset: runStart,
        length: (zeroCount + 1) as 3 | 4
      })
    );
    requireH264(
      starts.length <= maximumNalUnits,
      path,
      "NAL-unit count exceeds the inspection budget",
      runStart
    );
    cursor += 1;
  }
  return Object.freeze(starts);
}

/** Converts EBSP to RBSP while rejecting non-canonical escape sequences. */
export function removeEmulationPrevention(
  ebsp: Uint8Array,
  path: string,
  absoluteOffset: number
): Uint8Array {
  requireH264(ebsp.length > 0, path, "NAL RBSP is empty", absoluteOffset);
  const rbsp = new Uint8Array(ebsp.length);
  let outputLength = 0;
  let zeroCount = 0;

  for (let index = 0; index < ebsp.length; index += 1) {
    const byte = ebsp[index];
    if (byte === undefined) {
      h264Invalid(path, "truncated EBSP", absoluteOffset + index);
    }

    if (zeroCount === 2) {
      if (byte === 0x03) {
        const escaped = ebsp[index + 1];
        requireH264(
          escaped !== undefined && escaped <= 0x03,
          path,
          "emulation_prevention_three_byte is not followed by 0x00..0x03",
          absoluteOffset + index
        );
        zeroCount = 0;
        continue;
      }
      requireH264(
        byte > 0x02,
        path,
        "unescaped start-code emulation sequence in EBSP",
        absoluteOffset + index
      );
    }

    rbsp[outputLength] = byte;
    outputLength += 1;
    zeroCount = byte === 0 ? zeroCount + 1 : 0;
  }

  return rbsp.slice(0, outputLength);
}
