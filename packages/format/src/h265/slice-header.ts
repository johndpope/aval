import {
  H265_NAL_BLA_N_LP,
  H265_NAL_BLA_W_LP,
  H265_NAL_BLA_W_RADL,
  H265_NAL_CRA_NUT,
  isH265IdrNalType,
  isH265RandomAccessNalType,
  type H265AnnexBNalUnit
} from "./annex-b.js";
import { H265RbspBitReader } from "./bit-reader.js";
import { requireH265 } from "./failure.js";
import {
  parseH265ShortTermReferencePictureSet,
  type H265ShortTermReferencePictureSet,
  type ParsedH265Pps,
  type ParsedH265Sps
} from "./parameter-sets.js";
import type { H265RandomAccessKind } from "./types.js";

export interface ParsedH265SliceHeader {
  readonly ppsId: number;
  readonly sliceType: "I" | "P" | "B";
  readonly pictureOrderCountLsb: number;
  readonly referencePictureSet: H265ShortTermReferencePictureSet;
  readonly randomAccess: H265RandomAccessKind | undefined;
  readonly noOutputOfPriorPictures: boolean;
}

export function parseH265SliceHeader(
  nal: H265AnnexBNalUnit,
  pps: ParsedH265Pps,
  sps: ParsedH265Sps,
  path: string
): ParsedH265SliceHeader {
  const reader = new H265RbspBitReader(nal.rbsp, path, nal.offset + 2);
  requireH265(
    reader.readBit("first_slice_segment_in_pic_flag"),
    path,
    "the production HEVC profile requires one slice segment per picture"
  );
  const randomAccess = randomAccessKind(nal.type);
  const noOutputOfPriorPictures = randomAccess === undefined
    ? false
    : reader.readBit("no_output_of_prior_pics_flag");
  const ppsId = reader.readUnsignedExpGolomb("slice_pic_parameter_set_id", 63);
  requireH265(ppsId === pps.id, path, "slice references an unexpected PPS");
  for (let index = 0; index < pps.numExtraSliceHeaderBits; index += 1) {
    reader.readBit(`slice_reserved_flag[${String(index)}]`);
  }
  const rawSliceType = reader.readUnsignedExpGolomb("slice_type", 2);
  const sliceType = rawSliceType === 2 ? "I" : rawSliceType === 1 ? "P" : "B";
  requireH265(
    randomAccess === undefined || sliceType === "I",
    path,
    "an HEVC random-access picture must be intra-coded"
  );
  if (pps.outputFlagPresent) reader.readBit("pic_output_flag");

  let pictureOrderCountLsb = 0;
  let referencePictureSet: H265ShortTermReferencePictureSet = Object.freeze({
    pictures: Object.freeze([])
  });
  if (!isH265IdrNalType(nal.type)) {
    pictureOrderCountLsb = reader.readBits(
      sps.log2MaxPictureOrderCountLsb,
      "slice_pic_order_cnt_lsb"
    );
    const fromSps = reader.readBit("short_term_ref_pic_set_sps_flag");
    if (fromSps) {
      requireH265(
        sps.shortTermReferencePictureSets.length > 0,
        path,
        "slice selects an absent SPS reference-picture set"
      );
      const indexWidth = ceilLog2(sps.shortTermReferencePictureSets.length);
      const index = indexWidth === 0
        ? 0
        : reader.readBits(indexWidth, "short_term_ref_pic_set_idx");
      const selected = sps.shortTermReferencePictureSets[index];
      requireH265(selected !== undefined, path, "slice RPS index is out of range");
      referencePictureSet = selected;
    } else {
      referencePictureSet = parseH265ShortTermReferencePictureSet(
        reader,
        sps.shortTermReferencePictureSets.length,
        sps.shortTermReferencePictureSets.length,
        sps.shortTermReferencePictureSets
      );
    }
    requireH265(
      !sps.longTermReferencePicturesPresent,
      path,
      "long-term references are outside the production HEVC profile"
    );
    if (sps.temporalMvpEnabled) reader.readBit("slice_temporal_mvp_enabled_flag");
  }
  requireH265(
    reader.bitsRemaining >= 8,
    path,
    "slice header or coded slice payload is truncated"
  );
  return Object.freeze({
    ppsId,
    sliceType,
    pictureOrderCountLsb,
    referencePictureSet,
    randomAccess,
    noOutputOfPriorPictures
  });
}

function randomAccessKind(type: number): H265RandomAccessKind | undefined {
  if (!isH265RandomAccessNalType(type)) return undefined;
  if (
    type === H265_NAL_BLA_W_LP ||
    type === H265_NAL_BLA_W_RADL ||
    type === H265_NAL_BLA_N_LP
  ) return "bla";
  if (type === H265_NAL_CRA_NUT) return "cra";
  return "idr";
}

function ceilLog2(value: number): number {
  return value <= 1 ? 0 : Math.ceil(Math.log2(value));
}
