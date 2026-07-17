/// Slice header syntax parser for the production H264 High-profile subset.
///
/// Dart port of `packages/format/src/h264/slice-header.ts`.
library;

import 'annex_b.dart' show H264_NAL_TYPE_IDR, AnnexBNalUnit;
import 'bit_reader.dart';
import 'failure.dart';
import 'parameter_sets.dart';
import 'types.dart' show H264SliceType;

class ParsedSliceHeader {
  const ParsedSliceHeader({
    required this.firstMacroblock,
    required this.sliceType,
    required this.ppsId,
    required this.frameNum,
    required this.referenceIdc,
    required this.idr,
    this.idrPicId,
    this.picOrderCntLsb,
    required this.deltaPicOrderCntBottom,
    required this.deltaPicOrderCnt0,
    required this.deltaPicOrderCnt1,
    required this.sliceQpDelta,
  });

  final int firstMacroblock;
  final H264SliceType sliceType;
  final int ppsId;
  final int frameNum;
  final int referenceIdc;
  final bool idr;
  final int? idrPicId;
  final int? picOrderCntLsb;
  final int deltaPicOrderCntBottom;
  final int deltaPicOrderCnt0;
  final int deltaPicOrderCnt1;
  final int sliceQpDelta;
}

ParsedSliceHeader parseSliceHeader(
  AnnexBNalUnit nal,
  ParsedPps pps,
  ParsedSps sps,
  int macroblocksPerFrame,
  String path,
) {
  final reader = RbspBitReader(nal.rbsp, path, nal.offset + 1);
  final firstMacroblock = reader.readUnsignedExpGolomb(
    'first_mb_in_slice',
    macroblocksPerFrame - 1,
  );
  final rawSliceType = reader.readUnsignedExpGolomb('slice_type', 9);
  final normalizedSliceType = rawSliceType % 5;
  requireH264(
    normalizedSliceType == 0 ||
        normalizedSliceType == 1 ||
        normalizedSliceType == 2,
    path,
    'only I, P, and B slices are permitted (SP/SI are forbidden)',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final sliceType = normalizedSliceType == 2
      ? 'I'
      : normalizedSliceType == 1
          ? 'B'
          : 'P';
  final idr = nal.type == H264_NAL_TYPE_IDR;
  requireH264(
    !idr || sliceType == 'I',
    path,
    'an IDR picture must contain only I slices',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );

  final ppsId = reader.readUnsignedExpGolomb('pic_parameter_set_id', 255);
  requireH264(
    ppsId == pps.id,
    path,
    'slice references an unexpected PPS',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final frameNum = reader.readBits(sps.frameNumBits, 'frame_num');
  final idrPicId =
      idr ? reader.readUnsignedExpGolomb('idr_pic_id', 65535) : null;

  int? picOrderCntLsb;
  var deltaPicOrderCntBottom = 0;
  var deltaPicOrderCnt0 = 0;
  var deltaPicOrderCnt1 = 0;
  final poc = sps.picOrderCount;
  if (poc is PicOrderCountType0) {
    picOrderCntLsb = reader.readBits(poc.lsbBits, 'pic_order_cnt_lsb');
    if (pps.bottomFieldPicOrderInFramePresent) {
      deltaPicOrderCntBottom =
          reader.readSignedExpGolomb('delta_pic_order_cnt_bottom');
    }
  } else if (poc is PicOrderCountType1 && !poc.deltaPicOrderAlwaysZero) {
    deltaPicOrderCnt0 = reader.readSignedExpGolomb('delta_pic_order_cnt[0]');
    if (pps.bottomFieldPicOrderInFramePresent) {
      deltaPicOrderCnt1 = reader.readSignedExpGolomb('delta_pic_order_cnt[1]');
    }
  }

  var numRefIdxL0ActiveMinus1 = pps.numRefIdxL0DefaultActiveMinus1;
  var numRefIdxL1ActiveMinus1 = pps.numRefIdxL1DefaultActiveMinus1;
  if (sliceType == 'B') {
    reader.readBit('direct_spatial_mv_pred_flag');
  }
  if (sliceType == 'P' || sliceType == 'B') {
    if (reader.readBit('num_ref_idx_active_override_flag')) {
      numRefIdxL0ActiveMinus1 =
          reader.readUnsignedExpGolomb('num_ref_idx_l0_active_minus1', 31);
      if (sliceType == 'B') {
        numRefIdxL1ActiveMinus1 =
            reader.readUnsignedExpGolomb('num_ref_idx_l1_active_minus1', 31);
      }
    }
    _parseReferenceListModifications(reader, sliceType);
  }

  if ((pps.weightedPrediction && sliceType == 'P') ||
      (pps.weightedBipredIdc == 1 && sliceType == 'B')) {
    _parsePredictionWeights(
      reader,
      numRefIdxL0ActiveMinus1,
      sliceType == 'B' ? numRefIdxL1ActiveMinus1 : null,
    );
  }

  if (idr) {
    reader.readBit('no_output_of_prior_pics_flag');
    requireH264(
      !reader.readBit('long_term_reference_flag'),
      path,
      'long-term IDR references are forbidden',
      nal.offset + 1 + (reader.bitOffset ~/ 8),
    );
  } else if (nal.referenceIdc != 0) {
    _parseReferencePictureMarking(reader, path, nal.offset + 1);
  }

  if (pps.entropyCoding && sliceType != 'I') {
    reader.readUnsignedExpGolomb('cabac_init_idc', 2);
  }

  final sliceQpDelta = reader.readSignedExpGolomb('slice_qp_delta', -87, 77);
  final finalQp = 26 + pps.picInitQpMinus26 + sliceQpDelta;
  requireH264(
    finalQp >= 0 && finalQp <= 51,
    path,
    'final slice QP is outside the 8-bit H264 range',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  if (pps.deblockingFilterControlPresent) {
    final disableDeblockingFilterIdc =
        reader.readUnsignedExpGolomb('disable_deblocking_filter_idc', 2);
    if (disableDeblockingFilterIdc != 1) {
      reader.readSignedExpGolomb('slice_alpha_c0_offset_div2', -6, 6);
      reader.readSignedExpGolomb('slice_beta_offset_div2', -6, 6);
    }
  }
  requireH264(
    reader.bitsRemaining > 0,
    path,
    'slice_data and RBSP trailing bits are missing',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );

  return ParsedSliceHeader(
    firstMacroblock: firstMacroblock,
    sliceType: sliceType,
    ppsId: ppsId,
    frameNum: frameNum,
    referenceIdc: nal.referenceIdc,
    idr: idr,
    idrPicId: idrPicId,
    picOrderCntLsb: picOrderCntLsb,
    deltaPicOrderCntBottom: deltaPicOrderCntBottom,
    deltaPicOrderCnt0: deltaPicOrderCnt0,
    deltaPicOrderCnt1: deltaPicOrderCnt1,
    sliceQpDelta: sliceQpDelta,
  );
}

void _parseReferencePictureMarking(
  RbspBitReader reader,
  String path,
  int absoluteOffset,
) {
  if (!reader.readBit('adaptive_ref_pic_marking_mode_flag')) return;
  for (var index = 0; index < 64; index += 1) {
    final operation = reader.readUnsignedExpGolomb(
      'memory_management_control_operation[$index]',
      6,
    );
    if (operation == 0) return;
    requireH264(
      operation == 1,
      path,
      'only short-term reference release is permitted',
      absoluteOffset + (reader.bitOffset ~/ 8),
    );
    reader.readUnsignedExpGolomb(
      'difference_of_pic_nums_minus1[$index]',
      65535,
    );
  }
  requireH264(
    false,
    path,
    'reference-picture marking exceeds the syntax budget',
    absoluteOffset + (reader.bitOffset ~/ 8),
  );
}

void _parseReferenceListModifications(
  RbspBitReader reader,
  H264SliceType sliceType,
) {
  _parseReferenceList(reader, 'l0');
  if (sliceType == 'B') {
    _parseReferenceList(reader, 'l1');
  }
}

void _parseReferenceList(RbspBitReader reader, String list) {
  if (!reader.readBit('ref_pic_list_modification_flag_$list')) return;
  for (var index = 0; index < 64; index += 1) {
    final operation = reader.readUnsignedExpGolomb(
      'modification_of_pic_nums_idc_$list[$index]',
      3,
    );
    if (operation == 3) return;
    if (operation == 0 || operation == 1) {
      reader.readUnsignedExpGolomb(
        'abs_diff_pic_num_minus1_$list[$index]',
        65535,
      );
    } else {
      requireH264(
        false,
        'slice',
        'long-term reference-list entries are forbidden in independent units',
      );
    }
  }
  requireH264(
    false,
    'slice',
    'reference-list modification exceeds the syntax budget',
  );
}

void _parsePredictionWeights(
  RbspBitReader reader,
  int list0Minus1,
  int? list1Minus1,
) {
  reader.readUnsignedExpGolomb('luma_log2_weight_denom', 7);
  reader.readUnsignedExpGolomb('chroma_log2_weight_denom', 7);
  _parsePredictionWeightList(reader, 'l0', list0Minus1 + 1);
  if (list1Minus1 != null) {
    _parsePredictionWeightList(reader, 'l1', list1Minus1 + 1);
  }
}

void _parsePredictionWeightList(
  RbspBitReader reader,
  String list,
  int count,
) {
  for (var index = 0; index < count; index += 1) {
    if (reader.readBit('luma_weight_${list}_flag[$index]')) {
      reader.readSignedExpGolomb('luma_weight_$list[$index]', -128, 127);
      reader.readSignedExpGolomb('luma_offset_$list[$index]', -128, 127);
    }
    if (reader.readBit('chroma_weight_${list}_flag[$index]')) {
      for (var component = 0; component < 2; component += 1) {
        reader.readSignedExpGolomb(
          'chroma_weight_$list[$index][$component]',
          -128,
          127,
        );
        reader.readSignedExpGolomb(
          'chroma_offset_$list[$index][$component]',
          -128,
          127,
        );
      }
    }
  }
}

bool samePrimaryPicture(ParsedSliceHeader left, ParsedSliceHeader right) {
  return left.sliceType == right.sliceType &&
      left.ppsId == right.ppsId &&
      left.frameNum == right.frameNum &&
      left.referenceIdc == right.referenceIdc &&
      left.idr == right.idr &&
      left.idrPicId == right.idrPicId &&
      left.picOrderCntLsb == right.picOrderCntLsb &&
      left.deltaPicOrderCntBottom == right.deltaPicOrderCntBottom &&
      left.deltaPicOrderCnt0 == right.deltaPicOrderCnt0 &&
      left.deltaPicOrderCnt1 == right.deltaPicOrderCnt1;
}
