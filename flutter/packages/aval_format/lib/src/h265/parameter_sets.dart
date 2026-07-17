/// HEVC VPS/SPS/PPS and short-term reference-picture-set parsing.
///
/// Dart port of `packages/format/src/h265/parameter-sets.ts`.
library;

import 'dart:typed_data';

import 'annex_b.dart' show H265AnnexBNalUnit;
import 'bit_reader.dart';
import 'failure.dart';
import 'types.dart' show H265ColorSummary, H265CropSummary;

const int _maxShortTermReferencePictures = 64;

/// Port of `H265ProfileTierLevel` (`src/h265/parameter-sets.ts:8`).
class H265ProfileTierLevel {
  const H265ProfileTierLevel({
    required this.profileSpace,
    required this.tierFlag,
    required this.profileIdc,
    required this.profileCompatibilityFlags,
    required this.constraintIndicatorFlags,
    required this.levelIdc,
  });

  /// One of `0`, `1`, `2`, `3`.
  final int profileSpace;
  final bool tierFlag;
  final int profileIdc;

  /// Compatibility flags numbered as in the codec-string registration.
  final int profileCompatibilityFlags;
  final List<int> constraintIndicatorFlags;
  final int levelIdc;
}

/// Port of `H265ShortTermReferencePicture` (`src/h265/parameter-sets.ts:18`).
class H265ShortTermReferencePicture {
  const H265ShortTermReferencePicture({
    required this.deltaPoc,
    required this.usedByCurrentPicture,
  });

  final int deltaPoc;
  final bool usedByCurrentPicture;
}

/// Port of `H265ShortTermReferencePictureSet`
/// (`src/h265/parameter-sets.ts:23`).
class H265ShortTermReferencePictureSet {
  const H265ShortTermReferencePictureSet({required this.pictures});

  /// Negative deltas in closest-to-farthest order, then positive deltas.
  final List<H265ShortTermReferencePicture> pictures;
}

/// Port of `ParsedH265Vps` (`src/h265/parameter-sets.ts:28`).
class ParsedH265Vps {
  const ParsedH265Vps({
    required this.id,
    required this.profileTierLevel,
    required this.payloadSignature,
  });

  final int id;

  /// Always `1`.
  final int maxSubLayers = 1;
  final H265ProfileTierLevel profileTierLevel;
  final String payloadSignature;
}

/// The VUI timing block of an [ParsedH265Sps].
///
/// TS anonymous `{ numUnitsInTick, timeScale } | undefined`
/// (`src/h265/parameter-sets.ts:57`).
class H265SpsTiming {
  const H265SpsTiming({required this.numUnitsInTick, required this.timeScale});

  final int numUnitsInTick;
  final int timeScale;
}

/// Port of `ParsedH265Sps` (`src/h265/parameter-sets.ts:35`).
class ParsedH265Sps {
  const ParsedH265Sps({
    required this.id,
    required this.videoParameterSetId,
    required this.profileTierLevel,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.log2MaxPictureOrderCountLsb,
    required this.maxDecPicBuffering,
    required this.maxNumReorderPics,
    required this.log2CtbSize,
    required this.shortTermReferencePictureSets,
    required this.longTermReferencePicturesPresent,
    required this.temporalMvpEnabled,
    required this.squareSampleAspect,
    required this.defaultDisplayWindowPresent,
    required this.timing,
    required this.color,
    required this.payloadSignature,
  });

  final int id;
  final int videoParameterSetId;

  /// Always `1`.
  final int maxSubLayers = 1;

  /// Always `true`.
  final bool temporalIdNesting = true;
  final H265ProfileTierLevel profileTierLevel;

  /// Always `1` (4:2:0).
  final int chromaFormatIdc = 1;

  /// Always `false`.
  final bool separateColourPlane = false;
  final int codedWidth;
  final int codedHeight;
  final H265CropSummary crop;

  /// Always `8`.
  final int bitDepthLuma = 8;

  /// Always `8`.
  final int bitDepthChroma = 8;
  final int log2MaxPictureOrderCountLsb;
  final int maxDecPicBuffering;
  final int maxNumReorderPics;
  final int log2CtbSize;
  final List<H265ShortTermReferencePictureSet> shortTermReferencePictureSets;
  final bool longTermReferencePicturesPresent;
  final bool temporalMvpEnabled;
  final bool squareSampleAspect;
  final bool defaultDisplayWindowPresent;
  final H265SpsTiming? timing;
  final H265ColorSummary color;
  final String payloadSignature;
}

/// Port of `ParsedH265Pps` (`src/h265/parameter-sets.ts:65`).
class ParsedH265Pps {
  const ParsedH265Pps({
    required this.id,
    required this.spsId,
    required this.dependentSliceSegmentsEnabled,
    required this.outputFlagPresent,
    required this.numExtraSliceHeaderBits,
    required this.tilesEnabled,
    required this.entropyCodingSyncEnabled,
    required this.payloadSignature,
  });

  final int id;
  final int spsId;
  final bool dependentSliceSegmentsEnabled;
  final bool outputFlagPresent;
  final int numExtraSliceHeaderBits;
  final bool tilesEnabled;
  final bool entropyCodingSyncEnabled;
  final String payloadSignature;
}

class _VuiInfo {
  const _VuiInfo({
    required this.squareSampleAspect,
    required this.defaultDisplayWindowPresent,
    required this.timing,
    required this.color,
  });

  final bool squareSampleAspect;
  final bool defaultDisplayWindowPresent;
  final H265SpsTiming? timing;
  final H265ColorSummary color;
}

/// Port of `parseH265Vps` (`src/h265/parameter-sets.ts:76`).
ParsedH265Vps parseH265Vps(H265AnnexBNalUnit nal, String path) {
  final reader = _readerFor(nal, path);
  final id = reader.readBits(4, 'vps_video_parameter_set_id');
  requireH265(
    reader.readBit('vps_base_layer_internal_flag'),
    path,
    'VPS base layer must be internal',
  );
  requireH265(
    reader.readBit('vps_base_layer_available_flag'),
    path,
    'VPS base layer must be available',
  );
  requireH265(
    reader.readBits(6, 'vps_max_layers_minus1') == 0,
    path,
    'multilayer HEVC is unsupported',
  );
  final maxSubLayersMinusOne = reader.readBits(3, 'vps_max_sub_layers_minus1');
  requireH265(
    maxSubLayersMinusOne == 0,
    path,
    'temporal sublayers are outside the initial HEVC profile',
  );
  requireH265(
    reader.readBit('vps_temporal_id_nesting_flag'),
    path,
    'VPS temporal_id_nesting_flag must be one',
  );
  requireH265(
    reader.readBits(16, 'vps_reserved_0xffff_16bits') == 0xffff,
    path,
    'VPS reserved bits are invalid',
  );
  final profileTierLevel =
      _parseProfileTierLevel(reader, maxSubLayersMinusOne, path);
  reader.readBit('vps_sub_layer_ordering_info_present_flag');
  final maxDecPicBufferingMinusOne = reader.readUnsignedExpGolomb(
    'vps_max_dec_pic_buffering_minus1',
    15,
  );
  final maxNumReorderPics = reader.readUnsignedExpGolomb(
    'vps_max_num_reorder_pics',
    15,
  );
  requireH265(
    maxNumReorderPics <= maxDecPicBufferingMinusOne,
    path,
    'VPS reorder depth exceeds its decoded-picture buffer',
  );
  reader.readUnsignedExpGolomb('vps_max_latency_increase_plus1');
  requireH265(
    reader.readBits(6, 'vps_max_layer_id') == 0,
    path,
    'VPS maximum layer id must be zero',
  );
  requireH265(
    reader.readUnsignedExpGolomb('vps_num_layer_sets_minus1', 1023) == 0,
    path,
    'VPS layer sets are unsupported',
  );
  if (reader.readBit('vps_timing_info_present_flag')) {
    final numUnitsInTick = reader.readBits(32, 'vps_num_units_in_tick');
    final timeScale = reader.readBits(32, 'vps_time_scale');
    requireH265(
      numUnitsInTick > 0 && timeScale > 0,
      path,
      'VPS timing values must be positive',
    );
    if (reader.readBit('vps_poc_proportional_to_timing_flag')) {
      reader.readUnsignedExpGolomb('vps_num_ticks_poc_diff_one_minus1');
    }
    requireH265(
      reader.readUnsignedExpGolomb('vps_num_hrd_parameters', 1024) == 0,
      path,
      'VPS HRD parameter sets are outside the production profile',
    );
  }
  requireH265(
    !reader.readBit('vps_extension_flag'),
    path,
    'VPS extensions are outside the production profile',
  );
  reader.readTrailingBits();
  return ParsedH265Vps(
    id: id,
    profileTierLevel: profileTierLevel,
    payloadSignature: _h265PayloadSignature(nal.payload),
  );
}

/// Port of `parseH265Sps` (`src/h265/parameter-sets.ts:167`).
ParsedH265Sps parseH265Sps(H265AnnexBNalUnit nal, String path) {
  final reader = _readerFor(nal, path);
  final videoParameterSetId = reader.readBits(4, 'sps_video_parameter_set_id');
  final maxSubLayersMinusOne = reader.readBits(3, 'sps_max_sub_layers_minus1');
  requireH265(
    maxSubLayersMinusOne == 0,
    path,
    'temporal sublayers are outside the initial HEVC profile',
  );
  requireH265(
    reader.readBit('sps_temporal_id_nesting_flag'),
    path,
    'SPS temporal_id_nesting_flag must be one',
  );
  final profileTierLevel =
      _parseProfileTierLevel(reader, maxSubLayersMinusOne, path);
  final id = reader.readUnsignedExpGolomb('sps_seq_parameter_set_id', 15);
  final chromaFormatIdc = reader.readUnsignedExpGolomb('chroma_format_idc', 3);
  requireH265(
    chromaFormatIdc == 1,
    path,
    'the production HEVC profile requires 4:2:0 chroma',
  );
  final codedWidth = reader.readUnsignedExpGolomb(
    'pic_width_in_luma_samples',
    1048576,
  );
  final codedHeight = reader.readUnsignedExpGolomb(
    'pic_height_in_luma_samples',
    1048576,
  );
  requireH265(
    codedWidth > 0 && codedHeight > 0,
    path,
    'SPS coded dimensions must be positive',
  );
  var cropLeft = 0;
  var cropRight = 0;
  var cropTop = 0;
  var cropBottom = 0;
  if (reader.readBit('conformance_window_flag')) {
    cropLeft = reader.readUnsignedExpGolomb('conf_win_left_offset') * 2;
    cropRight = reader.readUnsignedExpGolomb('conf_win_right_offset') * 2;
    cropTop = reader.readUnsignedExpGolomb('conf_win_top_offset') * 2;
    cropBottom = reader.readUnsignedExpGolomb('conf_win_bottom_offset') * 2;
  }
  requireH265(
    cropLeft + cropRight < codedWidth && cropTop + cropBottom < codedHeight,
    path,
    'SPS conformance crop removes the complete picture',
  );
  final crop = H265CropSummary(
    left: cropLeft,
    right: cropRight,
    top: cropTop,
    bottom: cropBottom,
    visibleWidth: codedWidth - cropLeft - cropRight,
    visibleHeight: codedHeight - cropTop - cropBottom,
  );
  requireH265(
    reader.readUnsignedExpGolomb('bit_depth_luma_minus8', 8) == 0 &&
        reader.readUnsignedExpGolomb('bit_depth_chroma_minus8', 8) == 0,
    path,
    'the production HEVC profile requires 8-bit luma and chroma',
  );
  final log2MaxPictureOrderCountLsb =
      reader.readUnsignedExpGolomb('log2_max_pic_order_cnt_lsb_minus4', 12) + 4;
  final orderingInfoPresent =
      reader.readBit('sps_sub_layer_ordering_info_present_flag');
  final firstOrderingLayer = orderingInfoPresent ? 0 : maxSubLayersMinusOne;
  var maxDecPicBuffering = 0;
  var maxNumReorderPics = 0;
  for (var layer = firstOrderingLayer;
      layer <= maxSubLayersMinusOne;
      layer += 1) {
    maxDecPicBuffering = reader.readUnsignedExpGolomb(
          'sps_max_dec_pic_buffering_minus1[$layer]',
          15,
        ) +
        1;
    maxNumReorderPics = reader.readUnsignedExpGolomb(
      'sps_max_num_reorder_pics[$layer]',
      15,
    );
    requireH265(
      maxNumReorderPics < maxDecPicBuffering,
      path,
      'SPS reorder depth must fit its decoded-picture buffer',
    );
    reader.readUnsignedExpGolomb('sps_max_latency_increase_plus1[$layer]');
  }
  final log2MinLumaCodingBlockSize =
      reader.readUnsignedExpGolomb('log2_min_luma_coding_block_size_minus3', 3) +
          3;
  final log2DiffMaxMinLumaCodingBlockSize = reader.readUnsignedExpGolomb(
    'log2_diff_max_min_luma_coding_block_size',
    6,
  );
  final log2CtbSize =
      log2MinLumaCodingBlockSize + log2DiffMaxMinLumaCodingBlockSize;
  requireH265(log2CtbSize <= 6, path, 'SPS CTB size exceeds 64 luma samples');
  reader.readUnsignedExpGolomb('log2_min_luma_transform_block_size_minus2', 3);
  reader.readUnsignedExpGolomb('log2_diff_max_min_luma_transform_block_size', 3);
  reader.readUnsignedExpGolomb('max_transform_hierarchy_depth_inter', 6);
  reader.readUnsignedExpGolomb('max_transform_hierarchy_depth_intra', 6);
  if (reader.readBit('scaling_list_enabled_flag')) {
    if (reader.readBit('sps_scaling_list_data_present_flag')) {
      _skipScalingListData(reader);
    }
  }
  reader.readBit('amp_enabled_flag');
  reader.readBit('sample_adaptive_offset_enabled_flag');
  if (reader.readBit('pcm_enabled_flag')) {
    reader.readBits(4, 'pcm_sample_bit_depth_luma_minus1');
    reader.readBits(4, 'pcm_sample_bit_depth_chroma_minus1');
    reader.readUnsignedExpGolomb(
      'log2_min_pcm_luma_coding_block_size_minus3',
      3,
    );
    reader.readUnsignedExpGolomb(
      'log2_diff_max_min_pcm_luma_coding_block_size',
      3,
    );
    reader.readBit('pcm_loop_filter_disabled_flag');
  }
  final numberOfShortTermSets = reader.readUnsignedExpGolomb(
    'num_short_term_ref_pic_sets',
    _maxShortTermReferencePictures,
  );
  final shortTermReferencePictureSets = <H265ShortTermReferencePictureSet>[];
  for (var index = 0; index < numberOfShortTermSets; index += 1) {
    shortTermReferencePictureSets.add(
      parseH265ShortTermReferencePictureSet(
        reader,
        index,
        numberOfShortTermSets,
        shortTermReferencePictureSets,
      ),
    );
  }
  final longTermReferencePicturesPresent =
      reader.readBit('long_term_ref_pics_present_flag');
  if (longTermReferencePicturesPresent) {
    final count = reader.readUnsignedExpGolomb('num_long_term_ref_pics_sps', 32);
    for (var index = 0; index < count; index += 1) {
      reader.readBits(
        log2MaxPictureOrderCountLsb,
        'lt_ref_pic_poc_lsb_sps[$index]',
      );
      reader.readBit('used_by_curr_pic_lt_sps_flag[$index]');
    }
  }
  final temporalMvpEnabled = reader.readBit('sps_temporal_mvp_enabled_flag');
  reader.readBit('strong_intra_smoothing_enabled_flag');
  final vui = reader.readBit('vui_parameters_present_flag')
      ? _parseVui(reader, maxSubLayersMinusOne, path)
      : _defaultVui();
  if (reader.readBit('sps_extension_present_flag')) {
    final extensionFlags = reader.readBits(8, 'SPS extension flags');
    requireH265(
      extensionFlags == 0,
      path,
      'SPS extensions are outside the production HEVC profile',
    );
  }
  reader.readTrailingBits();
  return ParsedH265Sps(
    id: id,
    videoParameterSetId: videoParameterSetId,
    profileTierLevel: profileTierLevel,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    crop: crop,
    log2MaxPictureOrderCountLsb: log2MaxPictureOrderCountLsb,
    maxDecPicBuffering: maxDecPicBuffering,
    maxNumReorderPics: maxNumReorderPics,
    log2CtbSize: log2CtbSize,
    shortTermReferencePictureSets:
        List.unmodifiable(shortTermReferencePictureSets),
    longTermReferencePicturesPresent: longTermReferencePicturesPresent,
    temporalMvpEnabled: temporalMvpEnabled,
    squareSampleAspect: vui.squareSampleAspect,
    defaultDisplayWindowPresent: vui.defaultDisplayWindowPresent,
    timing: vui.timing,
    color: vui.color,
    payloadSignature: _h265PayloadSignature(nal.payload),
  );
}

/// Port of `parseH265Pps` (`src/h265/parameter-sets.ts:358`).
ParsedH265Pps parseH265Pps(H265AnnexBNalUnit nal, String path) {
  final reader = _readerFor(nal, path);
  final id = reader.readUnsignedExpGolomb('pps_pic_parameter_set_id', 63);
  final spsId = reader.readUnsignedExpGolomb('pps_seq_parameter_set_id', 15);
  final dependentSliceSegmentsEnabled =
      reader.readBit('dependent_slice_segments_enabled_flag');
  final outputFlagPresent = reader.readBit('output_flag_present_flag');
  final numExtraSliceHeaderBits =
      reader.readBits(3, 'num_extra_slice_header_bits');
  reader.readBit('sign_data_hiding_enabled_flag');
  reader.readBit('cabac_init_present_flag');
  reader.readUnsignedExpGolomb('num_ref_idx_l0_default_active_minus1', 14);
  reader.readUnsignedExpGolomb('num_ref_idx_l1_default_active_minus1', 14);
  reader.readSignedExpGolomb('init_qp_minus26', -26, 25);
  reader.readBit('constrained_intra_pred_flag');
  reader.readBit('transform_skip_enabled_flag');
  if (reader.readBit('cu_qp_delta_enabled_flag')) {
    reader.readUnsignedExpGolomb('diff_cu_qp_delta_depth', 6);
  }
  reader.readSignedExpGolomb('pps_cb_qp_offset', -12, 12);
  reader.readSignedExpGolomb('pps_cr_qp_offset', -12, 12);
  reader.readBit('pps_slice_chroma_qp_offsets_present_flag');
  reader.readBit('weighted_pred_flag');
  reader.readBit('weighted_bipred_flag');
  reader.readBit('transquant_bypass_enabled_flag');
  final tilesEnabled = reader.readBit('tiles_enabled_flag');
  final entropyCodingSyncEnabled =
      reader.readBit('entropy_coding_sync_enabled_flag');
  if (tilesEnabled) {
    final columnsMinusOne =
        reader.readUnsignedExpGolomb('num_tile_columns_minus1', 19);
    final rowsMinusOne =
        reader.readUnsignedExpGolomb('num_tile_rows_minus1', 21);
    if (!reader.readBit('uniform_spacing_flag')) {
      for (var column = 0; column < columnsMinusOne; column += 1) {
        reader.readUnsignedExpGolomb('column_width_minus1[$column]');
      }
      for (var row = 0; row < rowsMinusOne; row += 1) {
        reader.readUnsignedExpGolomb('row_height_minus1[$row]');
      }
    }
    reader.readBit('loop_filter_across_tiles_enabled_flag');
  }
  reader.readBit('pps_loop_filter_across_slices_enabled_flag');
  if (reader.readBit('deblocking_filter_control_present_flag')) {
    reader.readBit('deblocking_filter_override_enabled_flag');
    final disabled = reader.readBit('pps_deblocking_filter_disabled_flag');
    if (!disabled) {
      reader.readSignedExpGolomb('pps_beta_offset_div2', -6, 6);
      reader.readSignedExpGolomb('pps_tc_offset_div2', -6, 6);
    }
  }
  if (reader.readBit('pps_scaling_list_data_present_flag')) {
    _skipScalingListData(reader);
  }
  reader.readBit('lists_modification_present_flag');
  reader.readUnsignedExpGolomb('log2_parallel_merge_level_minus2', 4);
  reader.readBit('slice_segment_header_extension_present_flag');
  if (reader.readBit('pps_extension_present_flag')) {
    final extensionFlags = reader.readBits(8, 'PPS extension flags');
    requireH265(
      extensionFlags == 0,
      path,
      'PPS extensions are outside the production HEVC profile',
    );
  }
  reader.readTrailingBits();
  return ParsedH265Pps(
    id: id,
    spsId: spsId,
    dependentSliceSegmentsEnabled: dependentSliceSegmentsEnabled,
    outputFlagPresent: outputFlagPresent,
    numExtraSliceHeaderBits: numExtraSliceHeaderBits,
    tilesEnabled: tilesEnabled,
    entropyCodingSyncEnabled: entropyCodingSyncEnabled,
    payloadSignature: _h265PayloadSignature(nal.payload),
  );
}

/// Port of `parseH265ShortTermReferencePictureSet`
/// (`src/h265/parameter-sets.ts:436`).
H265ShortTermReferencePictureSet parseH265ShortTermReferencePictureSet(
  H265RbspBitReader reader,
  int setIndex,
  int numberOfSpsSets,
  List<H265ShortTermReferencePictureSet> previousSets,
) {
  requireH265(
    setIndex >= 0 && setIndex <= numberOfSpsSets,
    'shortTermReferencePictureSet',
    'short-term reference-picture-set index is invalid',
  );
  if (setIndex != 0 && reader.readBit('inter_ref_pic_set_prediction_flag')) {
    final deltaIndexMinusOne = setIndex == numberOfSpsSets
        ? reader.readUnsignedExpGolomb('delta_idx_minus1', setIndex - 1)
        : 0;
    final referenceIndex = setIndex - (deltaIndexMinusOne + 1);
    final reference =
        (referenceIndex >= 0 && referenceIndex < previousSets.length)
            ? previousSets[referenceIndex]
            : null;
    requireH265(
      reference != null,
      'shortTermReferencePictureSet',
      'predicted reference-picture set points outside the SPS',
    );
    final deltaSign = reader.readBit('delta_rps_sign');
    final absoluteDelta =
        reader.readUnsignedExpGolomb('abs_delta_rps_minus1', 32767) + 1;
    final deltaRps = deltaSign ? -absoluteDelta : absoluteDelta;
    final candidates = <int>[
      for (final picture in reference!.pictures) picture.deltaPoc + deltaRps,
      deltaRps,
    ];
    final selected = <H265ShortTermReferencePicture>[];
    for (var index = 0; index < candidates.length; index += 1) {
      final used = reader.readBit('used_by_curr_pic_flag[$index]');
      final retained = used || reader.readBit('use_delta_flag[$index]');
      if (retained) {
        final deltaPoc = candidates[index];
        requireH265(
          deltaPoc != 0,
          'shortTermReferencePictureSet',
          'predicted RPS contains the current picture',
        );
        selected.add(
          H265ShortTermReferencePicture(
            deltaPoc: deltaPoc,
            usedByCurrentPicture: used,
          ),
        );
      }
    }
    return _freezeReferencePictureSet(selected);
  }

  final numberOfNegativePictures = reader.readUnsignedExpGolomb(
    'num_negative_pics',
    _maxShortTermReferencePictures,
  );
  final numberOfPositivePictures = reader.readUnsignedExpGolomb(
    'num_positive_pics',
    _maxShortTermReferencePictures,
  );
  requireH265(
    numberOfNegativePictures + numberOfPositivePictures <=
        _maxShortTermReferencePictures,
    'shortTermReferencePictureSet',
    'short-term reference-picture set exceeds the picture budget',
  );
  final pictures = <H265ShortTermReferencePicture>[];
  var delta = 0;
  for (var index = 0; index < numberOfNegativePictures; index += 1) {
    delta -=
        reader.readUnsignedExpGolomb('delta_poc_s0_minus1[$index]', 32767) + 1;
    pictures.add(
      H265ShortTermReferencePicture(
        deltaPoc: delta,
        usedByCurrentPicture:
            reader.readBit('used_by_curr_pic_s0_flag[$index]'),
      ),
    );
  }
  delta = 0;
  for (var index = 0; index < numberOfPositivePictures; index += 1) {
    delta +=
        reader.readUnsignedExpGolomb('delta_poc_s1_minus1[$index]', 32767) + 1;
    pictures.add(
      H265ShortTermReferencePicture(
        deltaPoc: delta,
        usedByCurrentPicture:
            reader.readBit('used_by_curr_pic_s1_flag[$index]'),
      ),
    );
  }
  return _freezeReferencePictureSet(pictures);
}

/// Port of `sameH265ProfileTierLevel` (`src/h265/parameter-sets.ts:527`).
bool sameH265ProfileTierLevel(
  H265ProfileTierLevel left,
  H265ProfileTierLevel right,
) {
  if (!(left.profileSpace == right.profileSpace &&
      left.tierFlag == right.tierFlag &&
      left.profileIdc == right.profileIdc &&
      left.profileCompatibilityFlags == right.profileCompatibilityFlags &&
      left.levelIdc == right.levelIdc &&
      left.constraintIndicatorFlags.length ==
          right.constraintIndicatorFlags.length)) {
    return false;
  }
  for (var index = 0;
      index < left.constraintIndicatorFlags.length;
      index += 1) {
    if (left.constraintIndicatorFlags[index] !=
        right.constraintIndicatorFlags[index]) {
      return false;
    }
  }
  return true;
}

H265ProfileTierLevel _parseProfileTierLevel(
  H265RbspBitReader reader,
  int maxSubLayersMinusOne,
  String path,
) {
  final profileSpace = reader.readBits(2, 'general_profile_space');
  final tierFlag = reader.readBit('general_tier_flag');
  final profileIdc = reader.readBits(5, 'general_profile_idc');
  var profileCompatibilityFlags = 0;
  for (var index = 0; index < 32; index += 1) {
    if (reader.readBit('general_profile_compatibility_flag[$index]')) {
      profileCompatibilityFlags += 1 << index;
    }
  }
  final constraintIndicatorFlags = <int>[];
  for (var index = 0; index < 6; index += 1) {
    constraintIndicatorFlags.add(
      reader.readBits(8, 'general_constraint_indicator_flags[$index]'),
    );
  }
  final levelIdc = reader.readBits(8, 'general_level_idc');
  requireH265(levelIdc > 0, path, 'general_level_idc must be nonzero');

  final subLayerProfilePresent = <bool>[];
  final subLayerLevelPresent = <bool>[];
  for (var layer = 0; layer < maxSubLayersMinusOne; layer += 1) {
    subLayerProfilePresent.add(
      reader.readBit('sub_layer_profile_present_flag[$layer]'),
    );
    subLayerLevelPresent.add(
      reader.readBit('sub_layer_level_present_flag[$layer]'),
    );
  }
  if (maxSubLayersMinusOne > 0) {
    for (var layer = maxSubLayersMinusOne; layer < 8; layer += 1) {
      requireH265(
        reader.readBits(2, 'reserved_zero_2bits[$layer]') == 0,
        path,
        'profile-tier-level reserved bits must be zero',
      );
    }
  }
  for (var layer = 0; layer < maxSubLayersMinusOne; layer += 1) {
    if (subLayerProfilePresent[layer]) {
      reader.skipBits(88, 'sub_layer_profile_tier_level[$layer]');
    }
    if (subLayerLevelPresent[layer]) {
      reader.skipBits(8, 'sub_layer_level_idc[$layer]');
    }
  }
  return H265ProfileTierLevel(
    profileSpace: profileSpace,
    tierFlag: tierFlag,
    profileIdc: profileIdc,
    profileCompatibilityFlags: profileCompatibilityFlags,
    constraintIndicatorFlags: List.unmodifiable(constraintIndicatorFlags),
    levelIdc: levelIdc,
  );
}

_VuiInfo _parseVui(
  H265RbspBitReader reader,
  int maxSubLayersMinusOne,
  String path,
) {
  var squareSampleAspect = true;
  if (reader.readBit('aspect_ratio_info_present_flag')) {
    final aspectRatioIdc = reader.readBits(8, 'aspect_ratio_idc');
    if (aspectRatioIdc == 255) {
      final width = reader.readBits(16, 'sar_width');
      final height = reader.readBits(16, 'sar_height');
      requireH265(
        width > 0 && height > 0,
        path,
        'sample aspect ratio is invalid',
      );
      squareSampleAspect = width == height;
    } else {
      squareSampleAspect = aspectRatioIdc == 1;
    }
  }
  if (reader.readBit('overscan_info_present_flag')) {
    reader.readBit('overscan_appropriate_flag');
  }
  var fullRange = false;
  int? colourPrimaries;
  int? transferCharacteristics;
  int? matrixCoefficients;
  if (reader.readBit('video_signal_type_present_flag')) {
    reader.readBits(3, 'video_format');
    fullRange = reader.readBit('video_full_range_flag');
    if (reader.readBit('colour_description_present_flag')) {
      colourPrimaries = reader.readBits(8, 'colour_primaries');
      transferCharacteristics = reader.readBits(8, 'transfer_characteristics');
      matrixCoefficients = reader.readBits(8, 'matrix_coefficients');
    }
  }
  if (reader.readBit('chroma_loc_info_present_flag')) {
    reader.readUnsignedExpGolomb('chroma_sample_loc_type_top_field', 5);
    reader.readUnsignedExpGolomb('chroma_sample_loc_type_bottom_field', 5);
  }
  reader.readBit('neutral_chroma_indication_flag');
  requireH265(
    !reader.readBit('field_seq_flag'),
    path,
    'field sequences are unsupported',
  );
  reader.readBit('frame_field_info_present_flag');
  final defaultDisplayWindowPresent =
      reader.readBit('default_display_window_flag');
  if (defaultDisplayWindowPresent) {
    reader.readUnsignedExpGolomb('def_disp_win_left_offset');
    reader.readUnsignedExpGolomb('def_disp_win_right_offset');
    reader.readUnsignedExpGolomb('def_disp_win_top_offset');
    reader.readUnsignedExpGolomb('def_disp_win_bottom_offset');
  }
  H265SpsTiming? timing;
  if (reader.readBit('vui_timing_info_present_flag')) {
    final numUnitsInTick = reader.readBits(32, 'vui_num_units_in_tick');
    final timeScale = reader.readBits(32, 'vui_time_scale');
    requireH265(
      numUnitsInTick > 0 && timeScale > 0,
      path,
      'VUI timing values must be positive',
    );
    timing = H265SpsTiming(numUnitsInTick: numUnitsInTick, timeScale: timeScale);
    if (reader.readBit('vui_poc_proportional_to_timing_flag')) {
      reader.readUnsignedExpGolomb('vui_num_ticks_poc_diff_one_minus1');
    }
    requireH265(
      !reader.readBit('vui_hrd_parameters_present_flag'),
      path,
      'VUI HRD parameters are outside the production profile',
    );
  }
  if (reader.readBit('bitstream_restriction_flag')) {
    reader.readBit('tiles_fixed_structure_flag');
    reader.readBit('motion_vectors_over_pic_boundaries_flag');
    reader.readBit('restricted_ref_pic_lists_flag');
    reader.readUnsignedExpGolomb('min_spatial_segmentation_idc', 4095);
    reader.readUnsignedExpGolomb('max_bytes_per_pic_denom', 16);
    reader.readUnsignedExpGolomb('max_bits_per_min_cu_denom', 16);
    reader.readUnsignedExpGolomb('log2_max_mv_length_horizontal', 16);
    reader.readUnsignedExpGolomb('log2_max_mv_length_vertical', 16);
  }
  final color = H265ColorSummary(
    fullRange: fullRange,
    colourPrimaries: colourPrimaries,
    transferCharacteristics: transferCharacteristics,
    matrixCoefficients: matrixCoefficients,
  );
  return _VuiInfo(
    squareSampleAspect: squareSampleAspect,
    defaultDisplayWindowPresent: defaultDisplayWindowPresent,
    timing: timing,
    color: color,
  );
}

_VuiInfo _defaultVui() {
  return const _VuiInfo(
    squareSampleAspect: true,
    defaultDisplayWindowPresent: false,
    timing: null,
    color: H265ColorSummary(fullRange: false),
  );
}

void _skipScalingListData(H265RbspBitReader reader) {
  for (var sizeId = 0; sizeId < 4; sizeId += 1) {
    final increment = sizeId == 3 ? 3 : 1;
    for (var matrixId = 0; matrixId < 6; matrixId += increment) {
      if (!reader.readBit('scaling_list_pred_mode_flag[$sizeId][$matrixId]')) {
        reader.readUnsignedExpGolomb(
          'scaling_list_pred_matrix_id_delta[$sizeId][$matrixId]',
          matrixId,
        );
        continue;
      }
      final rawCount = 1 << (4 + sizeId * 2);
      final coefficientCount = 64 < rawCount ? 64 : rawCount;
      if (sizeId > 1) {
        reader.readSignedExpGolomb(
          'scaling_list_dc_coef_minus8[$sizeId][$matrixId]',
          -7,
          247,
        );
      }
      for (var coefficient = 0;
          coefficient < coefficientCount;
          coefficient += 1) {
        reader.readSignedExpGolomb(
          'scaling_list_delta_coef[$sizeId][$matrixId][$coefficient]',
          -128,
          127,
        );
      }
    }
  }
}

H265ShortTermReferencePictureSet _freezeReferencePictureSet(
  List<H265ShortTermReferencePicture> pictures,
) {
  final sorted = List<H265ShortTermReferencePicture>.from(pictures)
    ..sort((left, right) {
      if (left.deltaPoc < 0 && right.deltaPoc >= 0) return -1;
      if (left.deltaPoc >= 0 && right.deltaPoc < 0) return 1;
      return left.deltaPoc < 0
          ? right.deltaPoc - left.deltaPoc
          : left.deltaPoc - right.deltaPoc;
    });
  for (var index = 0; index < sorted.length; index += 1) {
    requireH265(
      index == 0 || sorted[index].deltaPoc != sorted[index - 1].deltaPoc,
      'shortTermReferencePictureSet',
      'short-term reference-picture set contains duplicate POC deltas',
    );
  }
  return H265ShortTermReferencePictureSet(pictures: List.unmodifiable(sorted));
}

H265RbspBitReader _readerFor(H265AnnexBNalUnit nal, String path) {
  return H265RbspBitReader(nal.rbsp, path, nal.offset + 2);
}

String _h265PayloadSignature(Uint8List payload) {
  final buffer = StringBuffer();
  for (final byte in payload) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
