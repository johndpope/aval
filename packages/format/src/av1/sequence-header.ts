import { FormatError } from "../errors.js";
import { Av1BitReader } from "./bit-reader.js";

export interface Av1SequenceHeader {
  readonly profile: 0;
  readonly level: number;
  readonly tier: "M" | "H";
  readonly bitDepth: 8 | 10;
  readonly maxWidth: number;
  readonly maxHeight: number;
  readonly monochrome: false;
  readonly subsamplingX: 1;
  readonly subsamplingY: 1;
  readonly chromaSamplePosition: 0 | 1 | 2 | 3;
  readonly colorPrimaries: 1;
  readonly transferCharacteristics: 1;
  readonly matrixCoefficients: 1;
  readonly fullRange: false;
  readonly reducedStillPictureHeader: boolean;
  readonly frameIdNumbersPresent: boolean;
  readonly filmGrainParamsPresent: boolean;
}

/** Parse the single-layer Main-profile sequence-header subset emitted by AVAL. */
export function parseAv1SequenceHeader(
  payload: Uint8Array,
  path = "av1.sequenceHeader"
): Readonly<Av1SequenceHeader> {
  if (!(payload instanceof Uint8Array) || payload.byteLength === 0) {
    invalid("sequence header is empty", path);
  }
  const reader = new Av1BitReader(payload, path);
  const profile = reader.readBits(3, "seq_profile");
  requireAv1(profile === 0, path, "only Main profile is supported");
  const stillPicture = reader.readBit("still_picture");
  const reducedStillPictureHeader = reader.readBit("reduced_still_picture_header");
  requireAv1(!reducedStillPictureHeader || stillPicture, path, "reduced header requires still_picture");

  let level: number;
  let tier: "M" | "H" = "M";
  if (reducedStillPictureHeader) {
    level = reader.readBits(5, "seq_level_idx_0");
  } else {
    requireAv1(!reader.readBit("timing_info_present_flag"), path, "timing info is unsupported");
    const initialDisplayDelayPresent = reader.readBit("initial_display_delay_present_flag");
    requireAv1(
      reader.readBits(5, "operating_points_cnt_minus_1") === 0,
      path,
      "multiple operating points are unsupported"
    );
    requireAv1(reader.readBits(12, "operating_point_idc_0") === 0, path, "scalable operating points are unsupported");
    level = reader.readBits(5, "seq_level_idx_0");
    if (level > 7) tier = reader.readBit("seq_tier_0") ? "H" : "M";
    if (initialDisplayDelayPresent) {
      const present = reader.readBit("initial_display_delay_present_for_this_op_0");
      if (present) reader.readBits(4, "initial_display_delay_minus_1_0");
    }
  }

  const widthBits = reader.readBits(4, "frame_width_bits_minus_1") + 1;
  const heightBits = reader.readBits(4, "frame_height_bits_minus_1") + 1;
  const maxWidth = reader.readBits(widthBits, "max_frame_width_minus_1") + 1;
  const maxHeight = reader.readBits(heightBits, "max_frame_height_minus_1") + 1;
  let frameIdNumbersPresent = false;
  if (!reducedStillPictureHeader) {
    frameIdNumbersPresent = reader.readBit("frame_id_numbers_present_flag");
    if (frameIdNumbersPresent) {
      reader.readBits(4, "delta_frame_id_length_minus_2");
      reader.readBits(3, "additional_frame_id_length_minus_1");
    }
  }

  reader.readBit("use_128x128_superblock");
  reader.readBit("enable_filter_intra");
  reader.readBit("enable_intra_edge_filter");
  if (!reducedStillPictureHeader) {
    reader.readBit("enable_interintra_compound");
    reader.readBit("enable_masked_compound");
    reader.readBit("enable_warped_motion");
    reader.readBit("enable_dual_filter");
    const enableOrderHint = reader.readBit("enable_order_hint");
    if (enableOrderHint) {
      reader.readBit("enable_jnt_comp");
      reader.readBit("enable_ref_frame_mvs");
    }
    const chooseScreenContentTools = reader.readBit("seq_choose_screen_content_tools");
    const forceScreenContentTools = chooseScreenContentTools
      ? 2
      : Number(reader.readBit("seq_force_screen_content_tools"));
    if (forceScreenContentTools > 0) {
      const chooseIntegerMv = reader.readBit("seq_choose_integer_mv");
      if (!chooseIntegerMv) reader.readBit("seq_force_integer_mv");
    }
    if (enableOrderHint) reader.readBits(3, "order_hint_bits_minus_1");
  }
  reader.readBit("enable_superres");
  reader.readBit("enable_cdef");
  reader.readBit("enable_restoration");

  const highBitdepth = reader.readBit("high_bitdepth");
  const bitDepth: 8 | 10 = highBitdepth ? 10 : 8;
  const monochrome = reader.readBit("mono_chrome");
  requireAv1(!monochrome, path, "monochrome output is unsupported");
  const colorDescriptionPresent = reader.readBit("color_description_present_flag");
  requireAv1(colorDescriptionPresent, path, "explicit BT.709 color description is required");
  const colorPrimaries = reader.readBits(8, "color_primaries");
  const transferCharacteristics = reader.readBits(8, "transfer_characteristics");
  const matrixCoefficients = reader.readBits(8, "matrix_coefficients");
  requireAv1(
    colorPrimaries === 1 && transferCharacteristics === 1 && matrixCoefficients === 1,
    path,
    "color description must be BT.709"
  );
  requireAv1(!reader.readBit("color_range"), path, "limited color range is required");
  const chromaSamplePosition = reader.readBits(2, "chroma_sample_position") as 0 | 1 | 2 | 3;
  reader.readBit("separate_uv_delta_q");
  const filmGrainParamsPresent = reader.readBit("film_grain_params_present");
  reader.readTrailingBits();

  return Object.freeze({
    profile: 0,
    level,
    tier,
    bitDepth,
    maxWidth,
    maxHeight,
    monochrome: false,
    subsamplingX: 1,
    subsamplingY: 1,
    chromaSamplePosition,
    colorPrimaries: 1,
    transferCharacteristics: 1,
    matrixCoefficients: 1,
    fullRange: false,
    reducedStillPictureHeader,
    frameIdNumbersPresent,
    filmGrainParamsPresent
  });
}

function requireAv1(
  condition: boolean,
  path: string,
  message: string
): asserts condition {
  if (!condition) invalid(message, path);
}

function invalid(message: string, path: string): never {
  throw new FormatError("PROFILE_INVALID", `AV1 ${message}`, { path });
}
