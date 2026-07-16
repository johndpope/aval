/// Slice header syntax parser for the production AVC subset.
///
/// Dart port of `packages/format/src/avc/slice-header.ts`.
library;

import 'annex_b.dart' show AVC_NAL_TYPE_IDR, AnnexBNalUnit;
import 'bit_reader.dart';
import 'failure.dart';
import 'parameter_sets.dart';
import 'types.dart' show AvcSliceType;

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
  final AvcSliceType sliceType;
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
  requireAvc(
    normalizedSliceType == 0 || normalizedSliceType == 2,
    path,
    'only I and P slices are permitted (B/SP/SI are forbidden)',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );
  final sliceType = normalizedSliceType == 2 ? 'I' : 'P';
  final idr = nal.type == AVC_NAL_TYPE_IDR;
  requireAvc(
    !idr || sliceType == 'I',
    path,
    'an IDR picture must contain only I slices',
    nal.offset + 1 + (reader.bitOffset ~/ 8),
  );

  final ppsId = reader.readUnsignedExpGolomb('pic_parameter_set_id', 255);
  requireAvc(
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

  if (sliceType == 'P') {
    if (reader.readBit('num_ref_idx_active_override_flag')) {
      requireAvc(
        reader.readUnsignedExpGolomb('num_ref_idx_l0_active_minus1', 31) == 0,
        path,
        'P slices may use only one list0 reference',
        nal.offset + 1 + (reader.bitOffset ~/ 8),
      );
    }
    requireAvc(
      !reader.readBit('ref_pic_list_modification_flag_l0'),
      path,
      'reference-list reordering is forbidden',
      nal.offset + 1 + (reader.bitOffset ~/ 8),
    );
  }

  if (idr) {
    reader.readBit('no_output_of_prior_pics_flag');
    requireAvc(
      !reader.readBit('long_term_reference_flag'),
      path,
      'long-term IDR references are forbidden',
      nal.offset + 1 + (reader.bitOffset ~/ 8),
    );
  } else {
    requireAvc(
      !reader.readBit('adaptive_ref_pic_marking_mode_flag'),
      path,
      'adaptive and long-term reference marking are forbidden',
      nal.offset + 1 + (reader.bitOffset ~/ 8),
    );
  }

  final sliceQpDelta = reader.readSignedExpGolomb('slice_qp_delta', -87, 77);
  final finalQp = 26 + pps.picInitQpMinus26 + sliceQpDelta;
  requireAvc(
    finalQp >= 0 && finalQp <= 51,
    path,
    'final slice QP is outside the 8-bit AVC range',
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
  requireAvc(
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
