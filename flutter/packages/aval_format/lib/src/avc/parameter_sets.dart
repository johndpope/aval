/// H.264 SPS/PPS syntax parsing for the production Constrained Baseline
/// subset.
///
/// Dart port of `packages/format/src/avc/parameter-sets.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import 'annex_b.dart' show AnnexBNalUnit;
import 'bit_reader.dart';
import 'codec.dart' show AvcLevelIdc, isAvcLevelIdc;
import 'failure.dart';
import 'types.dart'
    show AvcColorSummary, AvcCropSummary, AvcQuantizationPolicy;

const int _baselineProfileIdc = 66;
final BigInt _maxHrdBits = BigInt.from(maxSafeInteger);

/// `numUnitsInTick`/`timeScale`/`fixedFrameRate` VUI timing terms.
class AvcSpsTiming {
  const AvcSpsTiming({
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
    required this.constraintSet2,
    required this.levelIdc,
    required this.frameNumBits,
    required this.picOrderCount,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.timing,
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
  final bool constraintSet2;
  final AvcLevelIdc levelIdc;
  final int frameNumBits;
  final PicOrderCountSyntax picOrderCount;

  /// Always `1`.
  int get maxNumRefFrames => 1;
  final int codedWidth;
  final int codedHeight;
  final AvcCropSummary crop;
  final AvcSpsTiming timing;

  /// Always `0`.
  int get maxNumReorderFrames => 0;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final int? hrdMaximumBitrate;
  final int? hrdMaximumCpbBits;
  final bool squareSampleAspect;
  final AvcColorSummary color;
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
    required this.bottomFieldPicOrderInFramePresent,
    required this.deblockingFilterControlPresent,
    required this.picInitQpMinus26,
  });

  final int id;
  final int spsId;

  /// Exact, immutable payload identity without retaining caller byte views.
  final String payloadSignature;
  final bool bottomFieldPicOrderInFramePresent;
  final bool deblockingFilterControlPresent;
  final int picInitQpMinus26;
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
    required this.maxDecFrameBuffering,
    required this.hrdPresent,
    this.hrdMaximumBitrate,
    this.hrdMaximumCpbBits,
    required this.squareSampleAspect,
    required this.color,
  });

  final AvcSpsTiming timing;
  final int maxDecFrameBuffering;
  final bool hrdPresent;
  final int? hrdMaximumBitrate;
  final int? hrdMaximumCpbBits;
  final bool squareSampleAspect;
  final AvcColorSummary color;
}

ParsedSps parseSps(
  AnnexBNalUnit nal,
  String path, [
  String compatibilityPolicy = 'strict',
]) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final profileIdc = reader.readBits(8, 'profile_idc');
  requireAvc(
    profileIdc == _baselineProfileIdc,
    path,
    'profile_idc must be Baseline (66)',
    nal.offset + 1,
  );

  final compatibility = reader.readBits(8, 'constraint flags');
  requireAvc(
    (compatibility & 0x80) != 0 && (compatibility & 0x40) != 0,
    path,
    'constraint_set0_flag and constraint_set1_flag must both be one',
    nal.offset + 2,
  );
  final levelIdc = reader.readBits(8, 'level_idc');
  requireAvc(
    isAvcLevelIdc(levelIdc),
    path,
    'level_idc must identify a supported AVC level',
    nal.offset + 3,
  );
  requireAvc(
    (compatibility & 0x0f) == 0,
    path,
    'constraint_set4..5 and reserved constraint bits must be zero',
    nal.offset + 2,
  );
  final constraintSet3 = (compatibility & 0x10) != 0;
  requireAvc(
    !constraintSet3 ||
        (compatibilityPolicy == 'encoder-candidate' &&
            levelIdc == 11 &&
            (compatibility & 0x20) == 0),
    path,
    'constraint_set3_flag is permitted only for an encoder Level 1b candidate',
    nal.offset + 2,
  );
  final constraintSet2 = (compatibility & 0x20) != 0;
  final id = reader.readUnsignedExpGolomb('seq_parameter_set_id', 31);
  final log2MaxFrameNumMinus4 =
      reader.readUnsignedExpGolomb('log2_max_frame_num_minus4', 12);
  final frameNumBits = log2MaxFrameNumMinus4 + 4;
  final picOrderCount = _parsePicOrderCount(reader);
  final maxNumRefFrames =
      reader.readUnsignedExpGolomb('max_num_ref_frames', 16);
  requireAvc(
    maxNumRefFrames == 1,
    path,
    'max_num_ref_frames must equal one',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    !reader.readBit('gaps_in_frame_num_value_allowed_flag'),
    path,
    'frame_num gaps are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );

  final widthInMacroblocks =
      reader.readUnsignedExpGolomb('pic_width_in_mbs_minus1', 8191) + 1;
  final heightInMapUnits =
      reader.readUnsignedExpGolomb('pic_height_in_map_units_minus1', 8191) +
          1;
  final frameMbsOnly = reader.readBit('frame_mbs_only_flag');
  requireAvc(
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

  // Baseline profile has chroma_format_idc 1 (4:2:0), so each crop unit is 2x2.
  final left = cropLeftOffset * 2;
  final right = cropRightOffset * 2;
  final top = cropTopOffset * 2;
  final bottom = cropBottomOffset * 2;
  requireAvc(
    left + right < codedWidth && top + bottom < codedHeight,
    path,
    'SPS crop removes the complete coded picture',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final crop = AvcCropSummary(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    visibleWidth: codedWidth - left - right,
    visibleHeight: codedHeight - top - bottom,
  );

  requireAvc(
    reader.readBit('vui_parameters_present_flag'),
    path,
    'VUI parameters are required by the initial AVC profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final vui = _parseVui(reader, maxNumRefFrames, path, nal.offset + 1);
  reader.readTrailingBits();

  return ParsedSps(
    id: id,
    payloadSignature: _createPayloadSignature(nal.payload),
    constraintSet2: constraintSet2,
    levelIdc: levelIdc,
    frameNumBits: frameNumBits,
    picOrderCount: picOrderCount,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    crop: crop,
    timing: vui.timing,
    maxDecFrameBuffering: vui.maxDecFrameBuffering,
    hrdPresent: vui.hrdPresent,
    hrdMaximumBitrate: vui.hrdMaximumBitrate,
    hrdMaximumCpbBits: vui.hrdMaximumCpbBits,
    squareSampleAspect: vui.squareSampleAspect,
    color: vui.color,
  );
}

ParsedPps parsePps(
  AnnexBNalUnit nal,
  String path,
  AvcQuantizationPolicy quantizationPolicy,
) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final id = reader.readUnsignedExpGolomb('pic_parameter_set_id', 255);
  final spsId = reader.readUnsignedExpGolomb('seq_parameter_set_id', 31);
  requireAvc(
    !reader.readBit('entropy_coding_mode_flag'),
    path,
    'CABAC is forbidden by Constrained Baseline',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final bottomFieldPicOrderInFramePresent =
      reader.readBit('bottom_field_pic_order_in_frame_present_flag');
  requireAvc(
    !bottomFieldPicOrderInFramePresent,
    path,
    'bottom-field picture order syntax is forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readUnsignedExpGolomb('num_slice_groups_minus1', 8) == 0,
    path,
    'slice groups/FMO are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readUnsignedExpGolomb('num_ref_idx_l0_default_active_minus1', 31) ==
        0,
    path,
    'the default list0 reference count must be one',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readUnsignedExpGolomb('num_ref_idx_l1_default_active_minus1', 31) ==
        0,
    path,
    'the default list1 reference count must be one',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    !reader.readBit('weighted_pred_flag'),
    path,
    'weighted prediction is forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readBits(2, 'weighted_bipred_idc') == 0,
    path,
    'weighted biprediction is forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final picInitQpMinus26 =
      reader.readSignedExpGolomb('pic_init_qp_minus26', -26, 25);
  requireAvc(
    quantizationPolicy != 'fixed-qp26-v0' || picInitQpMinus26 == 0,
    path,
    'pic_init_qp_minus26 must match the frozen AVC v0 profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readSignedExpGolomb('pic_init_qs_minus26', -26, 25) == 0,
    path,
    'pic_init_qs_minus26 must match the frozen encoder profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    reader.readSignedExpGolomb('chroma_qp_index_offset', -12, 12) == -2,
    path,
    'chroma_qp_index_offset must match the frozen encoder profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final deblockingFilterControlPresent =
      reader.readBit('deblocking_filter_control_present_flag');
  requireAvc(
    deblockingFilterControlPresent,
    path,
    'deblocking filter control must be present',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    !reader.readBit('constrained_intra_pred_flag'),
    path,
    'constrained intra prediction is outside the frozen encoder profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    !reader.readBit('redundant_pic_cnt_present_flag'),
    path,
    'redundant pictures are forbidden',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  requireAvc(
    !reader.moreRbspData(),
    path,
    'PPS extension syntax is not permitted by the production AVC profile',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  reader.readTrailingBits();

  return ParsedPps(
    id: id,
    spsId: spsId,
    payloadSignature: _createPayloadSignature(nal.payload),
    bottomFieldPicOrderInFramePresent: bottomFieldPicOrderInFramePresent,
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
      requireAvc(
        sarWidth > 0 && sarHeight > 0,
        path,
        'extended sample aspect ratio must be positive',
        absoluteOffset + (reader.bitOffset ~/ 8),
      );
      squareSampleAspect = sarWidth == sarHeight;
    } else {
      requireAvc(
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

  requireAvc(
    reader.readBit('timing_info_present_flag'),
    path,
    'VUI fixed timing is required',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  final numUnitsInTick = reader.readBits(32, 'num_units_in_tick');
  final timeScale = reader.readBits(32, 'time_scale');
  requireAvc(
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

  requireAvc(
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
  requireAvc(
    reader.readUnsignedExpGolomb('max_num_reorder_frames', 16) == 0,
    path,
    'max_num_reorder_frames must be zero',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
  final maxDecFrameBuffering =
      reader.readUnsignedExpGolomb('max_dec_frame_buffering', 16);
  requireAvc(
    maxDecFrameBuffering >= maxNumRefFrames,
    path,
    'max_dec_frame_buffering is smaller than max_num_ref_frames',
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
    timing: AvcSpsTiming(
      numUnitsInTick: numUnitsInTick,
      timeScale: timeScale,
      fixedFrameRate: fixedFrameRate,
    ),
    maxDecFrameBuffering: maxDecFrameBuffering,
    hrdPresent: nalHrd != null || vclHrd != null,
    hrdMaximumBitrate:
        (nalHrd == null && vclHrd == null) ? null : maximumBitrate,
    hrdMaximumCpbBits:
        (nalHrd == null && vclHrd == null) ? null : maximumCpbBits,
    squareSampleAspect: squareSampleAspect,
    color: AvcColorSummary(
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
    requireAvc(
      bitrate <= _maxHrdBits,
      path,
      'HRD bitrate exceeds the JavaScript safe-integer range',
      absoluteOffset + (reader.bitOffset ~/ 8),
    );
    requireAvc(
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
