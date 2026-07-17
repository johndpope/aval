/// H.264 SPS/PPS syntax parsing for the production High-profile subset.
///
/// Dart port of `packages/format/src/h264/parameter-sets.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import 'annex_b.dart' show AnnexBNalUnit;
import 'bit_reader.dart';
import 'codec.dart' show H264LevelIdc, isH264LevelIdc;
import 'failure.dart';
import 'types.dart' show H264ColorSummary, H264CropSummary;

const int _highProfileIdc = 100;
final BigInt _maxHrdBits = BigInt.from(maxSafeInteger);

/// `numUnitsInTick`/`timeScale`/`fixedFrameRate` VUI timing terms.
class H264SpsTiming {
  const H264SpsTiming({
    required this.numUnitsInTick,
    required this.timeScale,
    required this.fixedFrameRate,
  });

  final int numUnitsInTick;
  final int timeScale;
  final bool fixedFrameRate;
}

class ParsedSps {
  const ParsedSps({
    required this.id,
    required this.payloadSignature,
    required this.levelIdc,
    required this.frameNumBits,
    required this.picOrderCount,
    required this.maxNumRefFrames,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.timing,
    required this.maxNumReorderFrames,
    required this.maxDecFrameBuffering,
    required this.hrdPresent,
    this.hrdMaximumBitrate,
    this.hrdMaximumCpbBits,
    required this.squareSampleAspect,
    required this.color,
  });

  final int id;

  /// Exact, immutable payload identity without retaining caller byte views.
  final String payloadSignature;

  /// Always `100` in the TS source (`profileIdc: 100`).
  int get profileIdc => 100;
  final H264LevelIdc levelIdc;
  final int frameNumBits;
  final PicOrderCountSyntax picOrderCount;
  final int maxNumRefFrames;
  final int codedWidth;
  final int codedHeight;
  final H264CropSummary crop;
  final H264SpsTiming timing;
  final int maxNumReorderFrames;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final int? hrdMaximumBitrate;
  final int? hrdMaximumCpbBits;
  final bool squareSampleAspect;
  final H264ColorSummary color;
}

/// TS discriminated union `PicOrderCountSyntax`. [type] is the discriminant.
sealed class PicOrderCountSyntax {
  const PicOrderCountSyntax(this.type);

  /// `0 | 1 | 2`.
  final int type;
}

class PicOrderCountType0 extends PicOrderCountSyntax {
  const PicOrderCountType0({required this.lsbBits}) : super(0);

  final int lsbBits;
}

class PicOrderCountType1 extends PicOrderCountSyntax {
  const PicOrderCountType1({
    required this.deltaPicOrderAlwaysZero,
    required this.offsetForNonRefPic,
    required this.offsetForTopToBottomField,
    required this.offsetForRefFrame,
  }) : super(1);

  final bool deltaPicOrderAlwaysZero;
  final int offsetForNonRefPic;
  final int offsetForTopToBottomField;
  final List<int> offsetForRefFrame;
}

class PicOrderCountType2 extends PicOrderCountSyntax {
  const PicOrderCountType2() : super(2);
}

class ParsedPps {
  const ParsedPps({
    required this.id,
    required this.spsId,
    required this.payloadSignature,
    required this.entropyCoding,
    required this.bottomFieldPicOrderInFramePresent,
    required this.numRefIdxL0DefaultActiveMinus1,
    required this.numRefIdxL1DefaultActiveMinus1,
    required this.weightedPrediction,
    required this.weightedBipredIdc,
    required this.deblockingFilterControlPresent,
    required this.picInitQpMinus26,
  });

  final int id;
  final int spsId;

  /// Exact, immutable payload identity without retaining caller byte views.
  final String payloadSignature;
  final bool entropyCoding;
  final bool bottomFieldPicOrderInFramePresent;
  final int numRefIdxL0DefaultActiveMinus1;
  final int numRefIdxL1DefaultActiveMinus1;
  final bool weightedPrediction;
  final int weightedBipredIdc;
  final bool deblockingFilterControlPresent;
  final int picInitQpMinus26;

  /// Always `true` in the TS source (`transform8x8Mode: true`).
  bool get transform8x8Mode => true;
}

class _HrdSummary {
  const _HrdSummary({
    required this.maximumBitrate,
    required this.maximumCpbBits,
  });

  final int maximumBitrate;
  final int maximumCpbBits;
}

class _VuiSummary {
  const _VuiSummary({
    required this.timing,
    required this.maxNumReorderFrames,
    required this.maxDecFrameBuffering,
    required this.hrdPresent,
    this.hrdMaximumBitrate,
    this.hrdMaximumCpbBits,
    required this.squareSampleAspect,
    required this.color,
  });

  final H264SpsTiming timing;
  final int maxNumReorderFrames;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final int? hrdMaximumBitrate;
  final int? hrdMaximumCpbBits;
  final bool squareSampleAspect;
  final H264ColorSummary color;
}

ParsedSps parseSps(AnnexBNalUnit nal, String path) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final profileIdc = reader.readBits(8, 'profile_idc');
  requireH264(
    profileIdc == _highProfileIdc,
    path,
    'profile_idc must be High (100)',
    nal.offset + 1,
  );

  final compatibility = reader.readBits(8, 'constraint flags');
  requireH264(
    compatibility == 0,
    path,
    'High-profile constraint and reserved flags must be zero',
    nal.offset + 2,
  );
  final levelIdc = reader.readBits(8, 'level_idc');
  requireH264(
    isH264LevelIdc(levelIdc),
    path,
    'level_idc must identify a supported H264 level',
    nal.offset + 3,
  );
  final id = reader.readUnsignedExpGolomb('seq_parameter_set_id', 31);
  final chromaFormatIdc = reader.readUnsignedExpGolomb('chroma_format_idc', 3);
  requireH264(
    chromaFormatIdc == 1,
    path,
    'High-profile streams must use 4:2:0 chroma',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    reader.readUnsignedExpGolomb('bit_depth_luma_minus8', 6) == 0 &&
        reader.readUnsignedExpGolomb('bit_depth_chroma_minus8', 6) == 0,
    path,
    'High-profile streams must use 8-bit luma and chroma',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    !reader.readBit('qpprime_y_zero_transform_bypass_flag'),
    path,
    'lossless transform bypass is forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  if (reader.readBit('seq_scaling_matrix_present_flag')) {
    _parseScalingMatrices(reader, 8);
  }
  final log2MaxFrameNumMinus4 =
      reader.readUnsignedExpGolomb('log2_max_frame_num_minus4', 12);
  final frameNumBits = log2MaxFrameNumMinus4 + 4;
  final picOrderCount = _parsePicOrderCount(reader);
  final maxNumRefFrames =
      reader.readUnsignedExpGolomb('max_num_ref_frames', 16);
  requireH264(maxNumRefFrames > 0, path, 'max_num_ref_frames must be positive');
  requireH264(
    !reader.readBit('gaps_in_frame_num_value_allowed_flag'),
    path,
    'frame_num gaps are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );

  final widthInMacroblocks =
      reader.readUnsignedExpGolomb('pic_width_in_mbs_minus1', 8191) + 1;
  final heightInMapUnits =
      reader.readUnsignedExpGolomb('pic_height_in_map_units_minus1', 8191) + 1;
  final frameMbsOnly = reader.readBit('frame_mbs_only_flag');
  requireH264(
    frameMbsOnly,
    path,
    'interlaced and field-coded pictures are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  reader.readBit('direct_8x8_inference_flag');

  final codedWidth = widthInMacroblocks * 16;
  final codedHeight = heightInMapUnits * 16;
  var cropLeftOffset = 0;
  var cropRightOffset = 0;
  var cropTopOffset = 0;
  var cropBottomOffset = 0;
  if (reader.readBit('frame_cropping_flag')) {
    cropLeftOffset = reader.readUnsignedExpGolomb('frame_crop_left_offset');
    cropRightOffset = reader.readUnsignedExpGolomb('frame_crop_right_offset');
    cropTopOffset = reader.readUnsignedExpGolomb('frame_crop_top_offset');
    cropBottomOffset =
        reader.readUnsignedExpGolomb('frame_crop_bottom_offset');
  }

  // Progressive High profile with chroma_format_idc 1 uses 2x2 crop units.
  final left = cropLeftOffset * 2;
  final right = cropRightOffset * 2;
  final top = cropTopOffset * 2;
  final bottom = cropBottomOffset * 2;
  requireH264(
    left + right < codedWidth && top + bottom < codedHeight,
    path,
    'SPS crop removes the complete coded picture',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final crop = H264CropSummary(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    visibleWidth: codedWidth - left - right,
    visibleHeight: codedHeight - top - bottom,
  );

  requireH264(
    reader.readBit('vui_parameters_present_flag'),
    path,
    'VUI parameters are required by the H264 profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final vui = _parseVui(reader, maxNumRefFrames, path, nal.offset + 1);
  reader.readTrailingBits();

  return ParsedSps(
    id: id,
    payloadSignature: _createPayloadSignature(nal.payload),
    levelIdc: levelIdc,
    frameNumBits: frameNumBits,
    picOrderCount: picOrderCount,
    maxNumRefFrames: maxNumRefFrames,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    crop: crop,
    timing: vui.timing,
    maxNumReorderFrames: vui.maxNumReorderFrames,
    maxDecFrameBuffering: vui.maxDecFrameBuffering,
    hrdPresent: vui.hrdPresent,
    hrdMaximumBitrate: vui.hrdMaximumBitrate,
    hrdMaximumCpbBits: vui.hrdMaximumCpbBits,
    squareSampleAspect: vui.squareSampleAspect,
    color: vui.color,
  );
}

ParsedPps parsePps(AnnexBNalUnit nal, String path) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final id = reader.readUnsignedExpGolomb('pic_parameter_set_id', 255);
  final spsId = reader.readUnsignedExpGolomb('seq_parameter_set_id', 31);
  final entropyCoding = reader.readBit('entropy_coding_mode_flag');
  final bottomFieldPicOrderInFramePresent =
      reader.readBit('bottom_field_pic_order_in_frame_present_flag');
  requireH264(
    !bottomFieldPicOrderInFramePresent,
    path,
    'bottom-field picture order syntax is forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    reader.readUnsignedExpGolomb('num_slice_groups_minus1', 8) == 0,
    path,
    'slice groups/FMO are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final numRefIdxL0DefaultActiveMinus1 =
      reader.readUnsignedExpGolomb('num_ref_idx_l0_default_active_minus1', 31);
  final numRefIdxL1DefaultActiveMinus1 =
      reader.readUnsignedExpGolomb('num_ref_idx_l1_default_active_minus1', 31);
  final weightedPrediction = reader.readBit('weighted_pred_flag');
  final weightedBipredIdc = reader.readBits(2, 'weighted_bipred_idc');
  requireH264(
    weightedBipredIdc <= 2,
    path,
    'weighted_bipred_idc is reserved',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final picInitQpMinus26 =
      reader.readSignedExpGolomb('pic_init_qp_minus26', -26, 25);
  requireH264(
    reader.readSignedExpGolomb('pic_init_qs_minus26', -26, 25) == 0,
    path,
    'pic_init_qs_minus26 must match the frozen encoder profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  reader.readSignedExpGolomb('chroma_qp_index_offset', -12, 12);
  final deblockingFilterControlPresent =
      reader.readBit('deblocking_filter_control_present_flag');
  requireH264(
    deblockingFilterControlPresent,
    path,
    'deblocking filter control must be present',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    !reader.readBit('constrained_intra_pred_flag'),
    path,
    'constrained intra prediction is outside the production profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    !reader.readBit('redundant_pic_cnt_present_flag'),
    path,
    'redundant pictures are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireH264(
    reader.moreRbspData(),
    path,
    'High-profile PPS extension is required',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final transform8x8Mode = reader.readBit('transform_8x8_mode_flag');
  requireH264(
    transform8x8Mode,
    path,
    'the production H264 profile requires transform_8x8_mode_flag',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  if (reader.readBit('pic_scaling_matrix_present_flag')) {
    _parseScalingMatrices(reader, 8);
  }
  reader.readSignedExpGolomb('second_chroma_qp_index_offset', -12, 12);
  reader.readTrailingBits();

  return ParsedPps(
    id: id,
    spsId: spsId,
    payloadSignature: _createPayloadSignature(nal.payload),
    entropyCoding: entropyCoding,
    bottomFieldPicOrderInFramePresent: bottomFieldPicOrderInFramePresent,
    numRefIdxL0DefaultActiveMinus1: numRefIdxL0DefaultActiveMinus1,
    numRefIdxL1DefaultActiveMinus1: numRefIdxL1DefaultActiveMinus1,
    weightedPrediction: weightedPrediction,
    weightedBipredIdc: weightedBipredIdc,
    deblockingFilterControlPresent: deblockingFilterControlPresent,
    picInitQpMinus26: picInitQpMinus26,
  );
}

String _createPayloadSignature(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

void _parseScalingMatrices(RbspBitReader reader, int count) {
  for (var index = 0; index < count; index += 1) {
    if (reader.readBit('scaling_list_present_flag[$index]')) {
      _parseScalingList(reader, index < 6 ? 16 : 64, index);
    }
  }
}

void _parseScalingList(RbspBitReader reader, int size, int listIndex) {
  var lastScale = 8;
  var nextScale = 8;
  for (var entry = 0; entry < size; entry += 1) {
    if (nextScale != 0) {
      final delta = reader.readSignedExpGolomb(
        'scaling_list[$listIndex][$entry]',
        -128,
        127,
      );
      nextScale = (lastScale + delta + 256) % 256;
    }
    lastScale = nextScale == 0 ? lastScale : nextScale;
  }
}

PicOrderCountSyntax _parsePicOrderCount(RbspBitReader reader) {
  final type = reader.readUnsignedExpGolomb('pic_order_cnt_type', 2);
  if (type == 0) {
    final lsbBits =
        reader.readUnsignedExpGolomb('log2_max_pic_order_cnt_lsb_minus4', 12) +
            4;
    return PicOrderCountType0(lsbBits: lsbBits);
  }
  if (type == 2) {
    return const PicOrderCountType2();
  }

  final deltaPicOrderAlwaysZero =
      reader.readBit('delta_pic_order_always_zero_flag');
  final offsetForNonRefPic =
      reader.readSignedExpGolomb('offset_for_non_ref_pic');
  final offsetForTopToBottomField =
      reader.readSignedExpGolomb('offset_for_top_to_bottom_field');
  final cycleLength = reader.readUnsignedExpGolomb(
    'num_ref_frames_in_pic_order_cnt_cycle',
    255,
  );
  final offsetForRefFrame = <int>[];
  for (var index = 0; index < cycleLength; index += 1) {
    offsetForRefFrame
        .add(reader.readSignedExpGolomb('offset_for_ref_frame[$index]'));
  }
  return PicOrderCountType1(
    deltaPicOrderAlwaysZero: deltaPicOrderAlwaysZero,
    offsetForNonRefPic: offsetForNonRefPic,
    offsetForTopToBottomField: offsetForTopToBottomField,
    offsetForRefFrame: List.unmodifiable(offsetForRefFrame),
  );
}

_VuiSummary _parseVui(
  RbspBitReader reader,
  int maxNumRefFrames,
  String path,
  int absoluteOffset,
) {
  var squareSampleAspect = true;
  if (reader.readBit('aspect_ratio_info_present_flag')) {
    final aspectRatioIdc = reader.readBits(8, 'aspect_ratio_idc');
    if (aspectRatioIdc == 255) {
      final sarWidth = reader.readBits(16, 'sar_width');
      final sarHeight = reader.readBits(16, 'sar_height');
      requireH264(
        sarWidth > 0 && sarHeight > 0,
        path,
        'extended sample aspect ratio must be positive',
        absoluteOffset + (reader.bitOffset ~/ 8),
      );
      squareSampleAspect = sarWidth == sarHeight;
    } else {
      requireH264(
        aspectRatioIdc >= 1 && aspectRatioIdc <= 16,
        path,
        'aspect_ratio_idc is reserved',
        absoluteOffset + (reader.bitOffset ~/ 8),
      );
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

  requireH264(
    reader.readBit('timing_info_present_flag'),
    path,
    'VUI fixed timing is required',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  final numUnitsInTick = reader.readBits(32, 'num_units_in_tick');
  final timeScale = reader.readBits(32, 'time_scale');
  requireH264(
    numUnitsInTick > 0 && timeScale > 0,
    path,
    'VUI timing terms must be positive',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  // libx264 may leave this advisory flag clear for a CFR elementary stream.
  // The compiler proves CFR from source timestamps; the inspector still
  // requires exact VUI timing terms and checks them against that frame clock.
  final fixedFrameRate = reader.readBit('fixed_frame_rate_flag');

  final nalHrd = reader.readBit('nal_hrd_parameters_present_flag')
      ? _parseHrd(reader, path, absoluteOffset)
      : null;
  final vclHrd = reader.readBit('vcl_hrd_parameters_present_flag')
      ? _parseHrd(reader, path, absoluteOffset)
      : null;
  if (nalHrd != null || vclHrd != null) {
    reader.readBit('low_delay_hrd_flag');
  }
  reader.readBit('pic_struct_present_flag');

  requireH264(
    reader.readBit('bitstream_restriction_flag'),
    path,
    'VUI bitstream restrictions are required',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  reader.readBit('motion_vectors_over_pic_boundaries_flag');
  reader.readUnsignedExpGolomb('max_bytes_per_pic_denom', 16);
  reader.readUnsignedExpGolomb('max_bits_per_mb_denom', 16);
  reader.readUnsignedExpGolomb('log2_max_mv_length_horizontal', 32);
  reader.readUnsignedExpGolomb('log2_max_mv_length_vertical', 32);
  final maxNumReorderFrames =
      reader.readUnsignedExpGolomb('max_num_reorder_frames', 16);
  final maxDecFrameBuffering =
      reader.readUnsignedExpGolomb('max_dec_frame_buffering', 16);
  requireH264(
    maxDecFrameBuffering >= maxNumRefFrames,
    path,
    'max_dec_frame_buffering is smaller than max_num_ref_frames',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  requireH264(
    maxNumReorderFrames <= maxDecFrameBuffering,
    path,
    'max_num_reorder_frames exceeds max_dec_frame_buffering',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );

  final maximumBitrate = _maxInt(
    nalHrd?.maximumBitrate ?? 0,
    vclHrd?.maximumBitrate ?? 0,
  );
  final maximumCpbBits = _maxInt(
    nalHrd?.maximumCpbBits ?? 0,
    vclHrd?.maximumCpbBits ?? 0,
  );
  return _VuiSummary(
    timing: H264SpsTiming(
      numUnitsInTick: numUnitsInTick,
      timeScale: timeScale,
      fixedFrameRate: fixedFrameRate,
    ),
    maxNumReorderFrames: maxNumReorderFrames,
    maxDecFrameBuffering: maxDecFrameBuffering,
    hrdPresent: nalHrd != null || vclHrd != null,
    hrdMaximumBitrate:
        (nalHrd == null && vclHrd == null) ? null : maximumBitrate,
    hrdMaximumCpbBits:
        (nalHrd == null && vclHrd == null) ? null : maximumCpbBits,
    squareSampleAspect: squareSampleAspect,
    color: H264ColorSummary(
      fullRange: fullRange,
      colourPrimaries: colourPrimaries,
      transferCharacteristics: transferCharacteristics,
      matrixCoefficients: matrixCoefficients,
    ),
  );
}

int _maxInt(int left, int right) => left > right ? left : right;

_HrdSummary _parseHrd(RbspBitReader reader, String path, int absoluteOffset) {
  final cpbCount = reader.readUnsignedExpGolomb('cpb_cnt_minus1', 31) + 1;
  final bitRateScale = reader.readBits(4, 'bit_rate_scale');
  final cpbSizeScale = reader.readBits(4, 'cpb_size_scale');
  var maximumBitrate = BigInt.zero;
  var maximumCpbBits = BigInt.zero;
  for (var index = 0; index < cpbCount; index += 1) {
    final bitRateValue = BigInt.from(
          reader.readUnsignedExpGolomb('bit_rate_value_minus1[$index]'),
        ) +
        BigInt.one;
    final cpbSizeValue = BigInt.from(
          reader.readUnsignedExpGolomb('cpb_size_value_minus1[$index]'),
        ) +
        BigInt.one;
    final bitrate = bitRateValue << (6 + bitRateScale);
    final cpbBits = cpbSizeValue << (4 + cpbSizeScale);
    requireH264(
      bitrate <= _maxHrdBits,
      path,
      'HRD bitrate exceeds the JavaScript safe-integer range',
      absoluteOffset + (reader.bitOffset ~/ 8),
    );
    requireH264(
      cpbBits <= _maxHrdBits,
      path,
      'HRD CPB exceeds the JavaScript safe-integer range',
      absoluteOffset + (reader.bitOffset ~/ 8),
    );
    if (bitrate > maximumBitrate) {
      maximumBitrate = bitrate;
    }
    if (cpbBits > maximumCpbBits) {
      maximumCpbBits = cpbBits;
    }
    reader.readBit('cbr_flag[$index]');
  }
  reader.readBits(5, 'initial_cpb_removal_delay_length_minus1');
  reader.readBits(5, 'cpb_removal_delay_length_minus1');
  reader.readBits(5, 'dpb_output_delay_length_minus1');
  reader.readBits(5, 'time_offset_length');
  return _HrdSummary(
    maximumBitrate: maximumBitrate.toInt(),
    maximumCpbBits: maximumCpbBits.toInt(),
  );
}
