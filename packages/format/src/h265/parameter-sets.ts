import type { H265AnnexBNalUnit } from "./annex-b.js";
import { H265RbspBitReader } from "./bit-reader.js";
import { requireH265 } from "./failure.js";
import type { H265ColorSummary, H265CropSummary } from "./types.js";

const MAX_SHORT_TERM_REFERENCE_PICTURES = 64;

export interface H265ProfileTierLevel {
  readonly profileSpace: 0 | 1 | 2 | 3;
  readonly tierFlag: boolean;
  readonly profileIdc: number;
  /** Compatibility flags numbered as in the codec-string registration. */
  readonly profileCompatibilityFlags: number;
  readonly constraintIndicatorFlags: readonly number[];
  readonly levelIdc: number;
}

export interface H265ShortTermReferencePicture {
  readonly deltaPoc: number;
  readonly usedByCurrentPicture: boolean;
}

export interface H265ShortTermReferencePictureSet {
  /** Negative deltas in closest-to-farthest order, then positive deltas. */
  readonly pictures: readonly H265ShortTermReferencePicture[];
}

export interface ParsedH265Vps {
  readonly id: number;
  readonly maxSubLayers: 1;
  readonly profileTierLevel: H265ProfileTierLevel;
  readonly payloadSignature: string;
}

export interface ParsedH265Sps {
  readonly id: number;
  readonly videoParameterSetId: number;
  readonly maxSubLayers: 1;
  readonly temporalIdNesting: true;
  readonly profileTierLevel: H265ProfileTierLevel;
  readonly chromaFormatIdc: 1;
  readonly separateColourPlane: false;
  readonly codedWidth: number;
  readonly codedHeight: number;
  readonly crop: H265CropSummary;
  readonly bitDepthLuma: 8;
  readonly bitDepthChroma: 8;
  readonly log2MaxPictureOrderCountLsb: number;
  readonly maxDecPicBuffering: number;
  readonly maxNumReorderPics: number;
  readonly log2CtbSize: number;
  readonly shortTermReferencePictureSets: readonly H265ShortTermReferencePictureSet[];
  readonly longTermReferencePicturesPresent: boolean;
  readonly temporalMvpEnabled: boolean;
  readonly squareSampleAspect: boolean;
  readonly defaultDisplayWindowPresent: boolean;
  readonly timing: {
    readonly numUnitsInTick: number;
    readonly timeScale: number;
  } | undefined;
  readonly color: H265ColorSummary;
  readonly payloadSignature: string;
}

export interface ParsedH265Pps {
  readonly id: number;
  readonly spsId: number;
  readonly dependentSliceSegmentsEnabled: boolean;
  readonly outputFlagPresent: boolean;
  readonly numExtraSliceHeaderBits: number;
  readonly tilesEnabled: boolean;
  readonly entropyCodingSyncEnabled: boolean;
  readonly payloadSignature: string;
}

export function parseH265Vps(nal: H265AnnexBNalUnit, path: string): ParsedH265Vps {
  const reader = readerFor(nal, path);
  const id = reader.readBits(4, "vps_video_parameter_set_id");
  requireH265(
    reader.readBit("vps_base_layer_internal_flag"),
    path,
    "VPS base layer must be internal"
  );
  requireH265(
    reader.readBit("vps_base_layer_available_flag"),
    path,
    "VPS base layer must be available"
  );
  requireH265(
    reader.readBits(6, "vps_max_layers_minus1") === 0,
    path,
    "multilayer HEVC is unsupported"
  );
  const maxSubLayersMinusOne = reader.readBits(3, "vps_max_sub_layers_minus1");
  requireH265(
    maxSubLayersMinusOne === 0,
    path,
    "temporal sublayers are outside the initial HEVC profile"
  );
  requireH265(
    reader.readBit("vps_temporal_id_nesting_flag"),
    path,
    "VPS temporal_id_nesting_flag must be one"
  );
  requireH265(
    reader.readBits(16, "vps_reserved_0xffff_16bits") === 0xffff,
    path,
    "VPS reserved bits are invalid"
  );
  const profileTierLevel = parseProfileTierLevel(reader, maxSubLayersMinusOne, path);
  reader.readBit("vps_sub_layer_ordering_info_present_flag");
  const maxDecPicBufferingMinusOne = reader.readUnsignedExpGolomb(
    "vps_max_dec_pic_buffering_minus1",
    15
  );
  const maxNumReorderPics = reader.readUnsignedExpGolomb(
    "vps_max_num_reorder_pics",
    15
  );
  requireH265(
    maxNumReorderPics <= maxDecPicBufferingMinusOne,
    path,
    "VPS reorder depth exceeds its decoded-picture buffer"
  );
  reader.readUnsignedExpGolomb("vps_max_latency_increase_plus1");
  requireH265(
    reader.readBits(6, "vps_max_layer_id") === 0,
    path,
    "VPS maximum layer id must be zero"
  );
  requireH265(
    reader.readUnsignedExpGolomb("vps_num_layer_sets_minus1", 1_023) === 0,
    path,
    "VPS layer sets are unsupported"
  );
  if (reader.readBit("vps_timing_info_present_flag")) {
    const numUnitsInTick = reader.readBits(32, "vps_num_units_in_tick");
    const timeScale = reader.readBits(32, "vps_time_scale");
    requireH265(
      numUnitsInTick > 0 && timeScale > 0,
      path,
      "VPS timing values must be positive"
    );
    if (reader.readBit("vps_poc_proportional_to_timing_flag")) {
      reader.readUnsignedExpGolomb("vps_num_ticks_poc_diff_one_minus1");
    }
    requireH265(
      reader.readUnsignedExpGolomb("vps_num_hrd_parameters", 1_024) === 0,
      path,
      "VPS HRD parameter sets are outside the production profile"
    );
  }
  requireH265(
    !reader.readBit("vps_extension_flag"),
    path,
    "VPS extensions are outside the production profile"
  );
  reader.readTrailingBits();
  return Object.freeze({
    id,
    maxSubLayers: 1 as const,
    profileTierLevel,
    payloadSignature: h265PayloadSignature(nal.payload)
  });
}

export function parseH265Sps(nal: H265AnnexBNalUnit, path: string): ParsedH265Sps {
  const reader = readerFor(nal, path);
  const videoParameterSetId = reader.readBits(4, "sps_video_parameter_set_id");
  const maxSubLayersMinusOne = reader.readBits(3, "sps_max_sub_layers_minus1");
  requireH265(
    maxSubLayersMinusOne === 0,
    path,
    "temporal sublayers are outside the initial HEVC profile"
  );
  requireH265(
    reader.readBit("sps_temporal_id_nesting_flag"),
    path,
    "SPS temporal_id_nesting_flag must be one"
  );
  const profileTierLevel = parseProfileTierLevel(reader, maxSubLayersMinusOne, path);
  const id = reader.readUnsignedExpGolomb("sps_seq_parameter_set_id", 15);
  const chromaFormatIdc = reader.readUnsignedExpGolomb("chroma_format_idc", 3);
  requireH265(
    chromaFormatIdc === 1,
    path,
    "the production HEVC profile requires 4:2:0 chroma"
  );
  const codedWidth = reader.readUnsignedExpGolomb(
    "pic_width_in_luma_samples",
    1_048_576
  );
  const codedHeight = reader.readUnsignedExpGolomb(
    "pic_height_in_luma_samples",
    1_048_576
  );
  requireH265(
    codedWidth > 0 && codedHeight > 0,
    path,
    "SPS coded dimensions must be positive"
  );
  let cropLeft = 0;
  let cropRight = 0;
  let cropTop = 0;
  let cropBottom = 0;
  if (reader.readBit("conformance_window_flag")) {
    cropLeft = reader.readUnsignedExpGolomb("conf_win_left_offset") * 2;
    cropRight = reader.readUnsignedExpGolomb("conf_win_right_offset") * 2;
    cropTop = reader.readUnsignedExpGolomb("conf_win_top_offset") * 2;
    cropBottom = reader.readUnsignedExpGolomb("conf_win_bottom_offset") * 2;
  }
  requireH265(
    cropLeft + cropRight < codedWidth && cropTop + cropBottom < codedHeight,
    path,
    "SPS conformance crop removes the complete picture"
  );
  const crop = Object.freeze({
    left: cropLeft,
    right: cropRight,
    top: cropTop,
    bottom: cropBottom,
    visibleWidth: codedWidth - cropLeft - cropRight,
    visibleHeight: codedHeight - cropTop - cropBottom
  });
  requireH265(
    reader.readUnsignedExpGolomb("bit_depth_luma_minus8", 8) === 0 &&
      reader.readUnsignedExpGolomb("bit_depth_chroma_minus8", 8) === 0,
    path,
    "the production HEVC profile requires 8-bit luma and chroma"
  );
  const log2MaxPictureOrderCountLsb =
    reader.readUnsignedExpGolomb("log2_max_pic_order_cnt_lsb_minus4", 12) + 4;
  const orderingInfoPresent = reader.readBit(
    "sps_sub_layer_ordering_info_present_flag"
  );
  const firstOrderingLayer = orderingInfoPresent ? 0 : maxSubLayersMinusOne;
  let maxDecPicBuffering = 0;
  let maxNumReorderPics = 0;
  for (let layer = firstOrderingLayer; layer <= maxSubLayersMinusOne; layer += 1) {
    maxDecPicBuffering =
      reader.readUnsignedExpGolomb(
        `sps_max_dec_pic_buffering_minus1[${String(layer)}]`,
        15
      ) + 1;
    maxNumReorderPics = reader.readUnsignedExpGolomb(
      `sps_max_num_reorder_pics[${String(layer)}]`,
      15
    );
    requireH265(
      maxNumReorderPics < maxDecPicBuffering,
      path,
      "SPS reorder depth must fit its decoded-picture buffer"
    );
    reader.readUnsignedExpGolomb(
      `sps_max_latency_increase_plus1[${String(layer)}]`
    );
  }
  const log2MinLumaCodingBlockSize =
    reader.readUnsignedExpGolomb("log2_min_luma_coding_block_size_minus3", 3) + 3;
  const log2DiffMaxMinLumaCodingBlockSize = reader.readUnsignedExpGolomb(
    "log2_diff_max_min_luma_coding_block_size",
    6
  );
  const log2CtbSize =
    log2MinLumaCodingBlockSize + log2DiffMaxMinLumaCodingBlockSize;
  requireH265(log2CtbSize <= 6, path, "SPS CTB size exceeds 64 luma samples");
  reader.readUnsignedExpGolomb("log2_min_luma_transform_block_size_minus2", 3);
  reader.readUnsignedExpGolomb(
    "log2_diff_max_min_luma_transform_block_size",
    3
  );
  reader.readUnsignedExpGolomb("max_transform_hierarchy_depth_inter", 6);
  reader.readUnsignedExpGolomb("max_transform_hierarchy_depth_intra", 6);
  if (reader.readBit("scaling_list_enabled_flag")) {
    if (reader.readBit("sps_scaling_list_data_present_flag")) {
      skipScalingListData(reader);
    }
  }
  reader.readBit("amp_enabled_flag");
  reader.readBit("sample_adaptive_offset_enabled_flag");
  if (reader.readBit("pcm_enabled_flag")) {
    reader.readBits(4, "pcm_sample_bit_depth_luma_minus1");
    reader.readBits(4, "pcm_sample_bit_depth_chroma_minus1");
    reader.readUnsignedExpGolomb("log2_min_pcm_luma_coding_block_size_minus3", 3);
    reader.readUnsignedExpGolomb("log2_diff_max_min_pcm_luma_coding_block_size", 3);
    reader.readBit("pcm_loop_filter_disabled_flag");
  }
  const numberOfShortTermSets = reader.readUnsignedExpGolomb(
    "num_short_term_ref_pic_sets",
    MAX_SHORT_TERM_REFERENCE_PICTURES
  );
  const shortTermReferencePictureSets: H265ShortTermReferencePictureSet[] = [];
  for (let index = 0; index < numberOfShortTermSets; index += 1) {
    shortTermReferencePictureSets.push(
      parseH265ShortTermReferencePictureSet(
        reader,
        index,
        numberOfShortTermSets,
        shortTermReferencePictureSets
      )
    );
  }
  const longTermReferencePicturesPresent = reader.readBit(
    "long_term_ref_pics_present_flag"
  );
  if (longTermReferencePicturesPresent) {
    const count = reader.readUnsignedExpGolomb("num_long_term_ref_pics_sps", 32);
    for (let index = 0; index < count; index += 1) {
      reader.readBits(
        log2MaxPictureOrderCountLsb,
        `lt_ref_pic_poc_lsb_sps[${String(index)}]`
      );
      reader.readBit(`used_by_curr_pic_lt_sps_flag[${String(index)}]`);
    }
  }
  const temporalMvpEnabled = reader.readBit("sps_temporal_mvp_enabled_flag");
  reader.readBit("strong_intra_smoothing_enabled_flag");
  const vui = reader.readBit("vui_parameters_present_flag")
    ? parseVui(reader, maxSubLayersMinusOne, path)
    : defaultVui();
  if (reader.readBit("sps_extension_present_flag")) {
    const extensionFlags = reader.readBits(8, "SPS extension flags");
    requireH265(
      extensionFlags === 0,
      path,
      "SPS extensions are outside the production HEVC profile"
    );
  }
  reader.readTrailingBits();
  return Object.freeze({
    id,
    videoParameterSetId,
    maxSubLayers: 1 as const,
    temporalIdNesting: true as const,
    profileTierLevel,
    chromaFormatIdc: 1 as const,
    separateColourPlane: false as const,
    codedWidth,
    codedHeight,
    crop,
    bitDepthLuma: 8 as const,
    bitDepthChroma: 8 as const,
    log2MaxPictureOrderCountLsb,
    maxDecPicBuffering,
    maxNumReorderPics,
    log2CtbSize,
    shortTermReferencePictureSets: Object.freeze(shortTermReferencePictureSets),
    longTermReferencePicturesPresent,
    temporalMvpEnabled,
    squareSampleAspect: vui.squareSampleAspect,
    defaultDisplayWindowPresent: vui.defaultDisplayWindowPresent,
    timing: vui.timing,
    color: vui.color,
    payloadSignature: h265PayloadSignature(nal.payload)
  });
}

export function parseH265Pps(nal: H265AnnexBNalUnit, path: string): ParsedH265Pps {
  const reader = readerFor(nal, path);
  const id = reader.readUnsignedExpGolomb("pps_pic_parameter_set_id", 63);
  const spsId = reader.readUnsignedExpGolomb("pps_seq_parameter_set_id", 15);
  const dependentSliceSegmentsEnabled = reader.readBit(
    "dependent_slice_segments_enabled_flag"
  );
  const outputFlagPresent = reader.readBit("output_flag_present_flag");
  const numExtraSliceHeaderBits = reader.readBits(3, "num_extra_slice_header_bits");
  reader.readBit("sign_data_hiding_enabled_flag");
  reader.readBit("cabac_init_present_flag");
  reader.readUnsignedExpGolomb("num_ref_idx_l0_default_active_minus1", 14);
  reader.readUnsignedExpGolomb("num_ref_idx_l1_default_active_minus1", 14);
  reader.readSignedExpGolomb("init_qp_minus26", -26, 25);
  reader.readBit("constrained_intra_pred_flag");
  reader.readBit("transform_skip_enabled_flag");
  if (reader.readBit("cu_qp_delta_enabled_flag")) {
    reader.readUnsignedExpGolomb("diff_cu_qp_delta_depth", 6);
  }
  reader.readSignedExpGolomb("pps_cb_qp_offset", -12, 12);
  reader.readSignedExpGolomb("pps_cr_qp_offset", -12, 12);
  reader.readBit("pps_slice_chroma_qp_offsets_present_flag");
  reader.readBit("weighted_pred_flag");
  reader.readBit("weighted_bipred_flag");
  reader.readBit("transquant_bypass_enabled_flag");
  const tilesEnabled = reader.readBit("tiles_enabled_flag");
  const entropyCodingSyncEnabled = reader.readBit(
    "entropy_coding_sync_enabled_flag"
  );
  if (tilesEnabled) {
    const columnsMinusOne = reader.readUnsignedExpGolomb("num_tile_columns_minus1", 19);
    const rowsMinusOne = reader.readUnsignedExpGolomb("num_tile_rows_minus1", 21);
    if (!reader.readBit("uniform_spacing_flag")) {
      for (let column = 0; column < columnsMinusOne; column += 1) {
        reader.readUnsignedExpGolomb(`column_width_minus1[${String(column)}]`);
      }
      for (let row = 0; row < rowsMinusOne; row += 1) {
        reader.readUnsignedExpGolomb(`row_height_minus1[${String(row)}]`);
      }
    }
    reader.readBit("loop_filter_across_tiles_enabled_flag");
  }
  reader.readBit("pps_loop_filter_across_slices_enabled_flag");
  if (reader.readBit("deblocking_filter_control_present_flag")) {
    reader.readBit("deblocking_filter_override_enabled_flag");
    const disabled = reader.readBit("pps_deblocking_filter_disabled_flag");
    if (!disabled) {
      reader.readSignedExpGolomb("pps_beta_offset_div2", -6, 6);
      reader.readSignedExpGolomb("pps_tc_offset_div2", -6, 6);
    }
  }
  if (reader.readBit("pps_scaling_list_data_present_flag")) {
    skipScalingListData(reader);
  }
  reader.readBit("lists_modification_present_flag");
  reader.readUnsignedExpGolomb("log2_parallel_merge_level_minus2", 4);
  reader.readBit("slice_segment_header_extension_present_flag");
  if (reader.readBit("pps_extension_present_flag")) {
    const extensionFlags = reader.readBits(8, "PPS extension flags");
    requireH265(
      extensionFlags === 0,
      path,
      "PPS extensions are outside the production HEVC profile"
    );
  }
  reader.readTrailingBits();
  return Object.freeze({
    id,
    spsId,
    dependentSliceSegmentsEnabled,
    outputFlagPresent,
    numExtraSliceHeaderBits,
    tilesEnabled,
    entropyCodingSyncEnabled,
    payloadSignature: h265PayloadSignature(nal.payload)
  });
}

export function parseH265ShortTermReferencePictureSet(
  reader: H265RbspBitReader,
  setIndex: number,
  numberOfSpsSets: number,
  previousSets: readonly H265ShortTermReferencePictureSet[]
): H265ShortTermReferencePictureSet {
  requireH265(
    setIndex >= 0 && setIndex <= numberOfSpsSets,
    "shortTermReferencePictureSet",
    "short-term reference-picture-set index is invalid"
  );
  if (setIndex !== 0 && reader.readBit("inter_ref_pic_set_prediction_flag")) {
    const deltaIndexMinusOne = setIndex === numberOfSpsSets
      ? reader.readUnsignedExpGolomb("delta_idx_minus1", setIndex - 1)
      : 0;
    const referenceIndex = setIndex - (deltaIndexMinusOne + 1);
    const reference = previousSets[referenceIndex];
    requireH265(
      reference !== undefined,
      "shortTermReferencePictureSet",
      "predicted reference-picture set points outside the SPS"
    );
    const deltaSign = reader.readBit("delta_rps_sign");
    const absoluteDelta =
      reader.readUnsignedExpGolomb("abs_delta_rps_minus1", 32_767) + 1;
    const deltaRps = deltaSign ? -absoluteDelta : absoluteDelta;
    const candidates = [
      ...reference.pictures.map((picture) => picture.deltaPoc + deltaRps),
      deltaRps
    ];
    const selected: H265ShortTermReferencePicture[] = [];
    for (let index = 0; index < candidates.length; index += 1) {
      const used = reader.readBit(`used_by_curr_pic_flag[${String(index)}]`);
      const retained = used || reader.readBit(`use_delta_flag[${String(index)}]`);
      if (retained) {
        const deltaPoc = candidates[index];
        requireH265(
          deltaPoc !== undefined && deltaPoc !== 0,
          "shortTermReferencePictureSet",
          "predicted RPS contains the current picture"
        );
        selected.push(Object.freeze({ deltaPoc, usedByCurrentPicture: used }));
      }
    }
    return freezeReferencePictureSet(selected);
  }

  const numberOfNegativePictures = reader.readUnsignedExpGolomb(
    "num_negative_pics",
    MAX_SHORT_TERM_REFERENCE_PICTURES
  );
  const numberOfPositivePictures = reader.readUnsignedExpGolomb(
    "num_positive_pics",
    MAX_SHORT_TERM_REFERENCE_PICTURES
  );
  requireH265(
    numberOfNegativePictures + numberOfPositivePictures <=
      MAX_SHORT_TERM_REFERENCE_PICTURES,
    "shortTermReferencePictureSet",
    "short-term reference-picture set exceeds the picture budget"
  );
  const pictures: H265ShortTermReferencePicture[] = [];
  let delta = 0;
  for (let index = 0; index < numberOfNegativePictures; index += 1) {
    delta -= reader.readUnsignedExpGolomb(
      `delta_poc_s0_minus1[${String(index)}]`,
      32_767
    ) + 1;
    pictures.push(Object.freeze({
      deltaPoc: delta,
      usedByCurrentPicture: reader.readBit(
        `used_by_curr_pic_s0_flag[${String(index)}]`
      )
    }));
  }
  delta = 0;
  for (let index = 0; index < numberOfPositivePictures; index += 1) {
    delta += reader.readUnsignedExpGolomb(
      `delta_poc_s1_minus1[${String(index)}]`,
      32_767
    ) + 1;
    pictures.push(Object.freeze({
      deltaPoc: delta,
      usedByCurrentPicture: reader.readBit(
        `used_by_curr_pic_s1_flag[${String(index)}]`
      )
    }));
  }
  return freezeReferencePictureSet(pictures);
}

export function sameH265ProfileTierLevel(
  left: H265ProfileTierLevel,
  right: H265ProfileTierLevel
): boolean {
  return left.profileSpace === right.profileSpace &&
    left.tierFlag === right.tierFlag &&
    left.profileIdc === right.profileIdc &&
    left.profileCompatibilityFlags === right.profileCompatibilityFlags &&
    left.levelIdc === right.levelIdc &&
    left.constraintIndicatorFlags.length === right.constraintIndicatorFlags.length &&
    left.constraintIndicatorFlags.every(
      (byte, index) => byte === right.constraintIndicatorFlags[index]
    );
}

function parseProfileTierLevel(
  reader: H265RbspBitReader,
  maxSubLayersMinusOne: number,
  path: string
): H265ProfileTierLevel {
  const profileSpace = reader.readBits(2, "general_profile_space") as 0 | 1 | 2 | 3;
  const tierFlag = reader.readBit("general_tier_flag");
  const profileIdc = reader.readBits(5, "general_profile_idc");
  let profileCompatibilityFlags = 0;
  for (let index = 0; index < 32; index += 1) {
    if (reader.readBit(`general_profile_compatibility_flag[${String(index)}]`)) {
      profileCompatibilityFlags += 2 ** index;
    }
  }
  const constraintIndicatorFlags: number[] = [];
  for (let index = 0; index < 6; index += 1) {
    constraintIndicatorFlags.push(
      reader.readBits(8, `general_constraint_indicator_flags[${String(index)}]`)
    );
  }
  const levelIdc = reader.readBits(8, "general_level_idc");
  requireH265(levelIdc > 0, path, "general_level_idc must be nonzero");

  const subLayerProfilePresent: boolean[] = [];
  const subLayerLevelPresent: boolean[] = [];
  for (let layer = 0; layer < maxSubLayersMinusOne; layer += 1) {
    subLayerProfilePresent.push(
      reader.readBit(`sub_layer_profile_present_flag[${String(layer)}]`)
    );
    subLayerLevelPresent.push(
      reader.readBit(`sub_layer_level_present_flag[${String(layer)}]`)
    );
  }
  if (maxSubLayersMinusOne > 0) {
    for (let layer = maxSubLayersMinusOne; layer < 8; layer += 1) {
      requireH265(
        reader.readBits(2, `reserved_zero_2bits[${String(layer)}]`) === 0,
        path,
        "profile-tier-level reserved bits must be zero"
      );
    }
  }
  for (let layer = 0; layer < maxSubLayersMinusOne; layer += 1) {
    if (subLayerProfilePresent[layer]) {
      reader.skipBits(88, `sub_layer_profile_tier_level[${String(layer)}]`);
    }
    if (subLayerLevelPresent[layer]) {
      reader.skipBits(8, `sub_layer_level_idc[${String(layer)}]`);
    }
  }
  return Object.freeze({
    profileSpace,
    tierFlag,
    profileIdc,
    profileCompatibilityFlags,
    constraintIndicatorFlags: Object.freeze(constraintIndicatorFlags),
    levelIdc
  });
}

function parseVui(
  reader: H265RbspBitReader,
  _maxSubLayersMinusOne: number,
  path: string
): {
  readonly squareSampleAspect: boolean;
  readonly defaultDisplayWindowPresent: boolean;
  readonly timing: { readonly numUnitsInTick: number; readonly timeScale: number } | undefined;
  readonly color: H265ColorSummary;
} {
  let squareSampleAspect = true;
  if (reader.readBit("aspect_ratio_info_present_flag")) {
    const aspectRatioIdc = reader.readBits(8, "aspect_ratio_idc");
    if (aspectRatioIdc === 255) {
      const width = reader.readBits(16, "sar_width");
      const height = reader.readBits(16, "sar_height");
      requireH265(width > 0 && height > 0, path, "sample aspect ratio is invalid");
      squareSampleAspect = width === height;
    } else {
      squareSampleAspect = aspectRatioIdc === 1;
    }
  }
  if (reader.readBit("overscan_info_present_flag")) {
    reader.readBit("overscan_appropriate_flag");
  }
  let fullRange = false;
  let colourPrimaries: number | undefined;
  let transferCharacteristics: number | undefined;
  let matrixCoefficients: number | undefined;
  if (reader.readBit("video_signal_type_present_flag")) {
    reader.readBits(3, "video_format");
    fullRange = reader.readBit("video_full_range_flag");
    if (reader.readBit("colour_description_present_flag")) {
      colourPrimaries = reader.readBits(8, "colour_primaries");
      transferCharacteristics = reader.readBits(8, "transfer_characteristics");
      matrixCoefficients = reader.readBits(8, "matrix_coefficients");
    }
  }
  if (reader.readBit("chroma_loc_info_present_flag")) {
    reader.readUnsignedExpGolomb("chroma_sample_loc_type_top_field", 5);
    reader.readUnsignedExpGolomb("chroma_sample_loc_type_bottom_field", 5);
  }
  reader.readBit("neutral_chroma_indication_flag");
  requireH265(!reader.readBit("field_seq_flag"), path, "field sequences are unsupported");
  reader.readBit("frame_field_info_present_flag");
  const defaultDisplayWindowPresent = reader.readBit("default_display_window_flag");
  if (defaultDisplayWindowPresent) {
    reader.readUnsignedExpGolomb("def_disp_win_left_offset");
    reader.readUnsignedExpGolomb("def_disp_win_right_offset");
    reader.readUnsignedExpGolomb("def_disp_win_top_offset");
    reader.readUnsignedExpGolomb("def_disp_win_bottom_offset");
  }
  let timing: { readonly numUnitsInTick: number; readonly timeScale: number } | undefined;
  if (reader.readBit("vui_timing_info_present_flag")) {
    const numUnitsInTick = reader.readBits(32, "vui_num_units_in_tick");
    const timeScale = reader.readBits(32, "vui_time_scale");
    requireH265(
      numUnitsInTick > 0 && timeScale > 0,
      path,
      "VUI timing values must be positive"
    );
    timing = Object.freeze({ numUnitsInTick, timeScale });
    if (reader.readBit("vui_poc_proportional_to_timing_flag")) {
      reader.readUnsignedExpGolomb("vui_num_ticks_poc_diff_one_minus1");
    }
    requireH265(
      !reader.readBit("vui_hrd_parameters_present_flag"),
      path,
      "VUI HRD parameters are outside the production profile"
    );
  }
  if (reader.readBit("bitstream_restriction_flag")) {
    reader.readBit("tiles_fixed_structure_flag");
    reader.readBit("motion_vectors_over_pic_boundaries_flag");
    reader.readBit("restricted_ref_pic_lists_flag");
    reader.readUnsignedExpGolomb("min_spatial_segmentation_idc", 4_095);
    reader.readUnsignedExpGolomb("max_bytes_per_pic_denom", 16);
    reader.readUnsignedExpGolomb("max_bits_per_min_cu_denom", 16);
    reader.readUnsignedExpGolomb("log2_max_mv_length_horizontal", 16);
    reader.readUnsignedExpGolomb("log2_max_mv_length_vertical", 16);
  }
  const color: H265ColorSummary = Object.freeze({
    fullRange,
    ...(colourPrimaries === undefined ? {} : { colourPrimaries }),
    ...(transferCharacteristics === undefined ? {} : { transferCharacteristics }),
    ...(matrixCoefficients === undefined ? {} : { matrixCoefficients })
  });
  return Object.freeze({
    squareSampleAspect,
    defaultDisplayWindowPresent,
    timing,
    color
  });
}

function defaultVui(): {
  readonly squareSampleAspect: true;
  readonly defaultDisplayWindowPresent: false;
  readonly timing: undefined;
  readonly color: H265ColorSummary;
} {
  return Object.freeze({
    squareSampleAspect: true as const,
    defaultDisplayWindowPresent: false as const,
    timing: undefined,
    color: Object.freeze({ fullRange: false })
  });
}

function skipScalingListData(reader: H265RbspBitReader): void {
  for (let sizeId = 0; sizeId < 4; sizeId += 1) {
    const increment = sizeId === 3 ? 3 : 1;
    for (let matrixId = 0; matrixId < 6; matrixId += increment) {
      if (!reader.readBit(`scaling_list_pred_mode_flag[${sizeId}][${matrixId}]`)) {
        reader.readUnsignedExpGolomb(
          `scaling_list_pred_matrix_id_delta[${sizeId}][${matrixId}]`,
          matrixId
        );
        continue;
      }
      const coefficientCount = Math.min(64, 1 << (4 + sizeId * 2));
      if (sizeId > 1) {
        reader.readSignedExpGolomb(
          `scaling_list_dc_coef_minus8[${sizeId}][${matrixId}]`,
          -7,
          247
        );
      }
      for (let coefficient = 0; coefficient < coefficientCount; coefficient += 1) {
        reader.readSignedExpGolomb(
          `scaling_list_delta_coef[${sizeId}][${matrixId}][${coefficient}]`,
          -128,
          127
        );
      }
    }
  }
}

function freezeReferencePictureSet(
  pictures: readonly H265ShortTermReferencePicture[]
): H265ShortTermReferencePictureSet {
  const sorted = [...pictures].sort((left, right) => {
    if (left.deltaPoc < 0 && right.deltaPoc >= 0) return -1;
    if (left.deltaPoc >= 0 && right.deltaPoc < 0) return 1;
    return left.deltaPoc < 0
      ? right.deltaPoc - left.deltaPoc
      : left.deltaPoc - right.deltaPoc;
  });
  requireH265(
    sorted.every(
      (picture, index) => index === 0 || picture.deltaPoc !== sorted[index - 1]?.deltaPoc
    ),
    "shortTermReferencePictureSet",
    "short-term reference-picture set contains duplicate POC deltas"
  );
  return Object.freeze({ pictures: Object.freeze(sorted) });
}

function readerFor(nal: H265AnnexBNalUnit, path: string): H265RbspBitReader {
  return new H265RbspBitReader(nal.rbsp, path, nal.offset + 2);
}

function h265PayloadSignature(payload: Uint8Array): string {
  let signature = "";
  for (const byte of payload) signature += byte.toString(16).padStart(2, "0");
  return signature;
}
