/// HEVC slice-segment header parsing (production profile subset).
///
/// Dart port of `packages/format/src/h265/slice-header.ts`.
library;

import 'annex_b.dart'
    show
        H265_NAL_BLA_N_LP,
        H265_NAL_BLA_W_LP,
        H265_NAL_BLA_W_RADL,
        H265_NAL_CRA_NUT,
        H265AnnexBNalUnit,
        isH265IdrNalType,
        isH265RandomAccessNalType;
import 'bit_reader.dart';
import 'failure.dart';
import 'parameter_sets.dart'
    show
        H265ShortTermReferencePictureSet,
        ParsedH265Pps,
        ParsedH265Sps,
        parseH265ShortTermReferencePictureSet;
import 'types.dart' show H265RandomAccessKind;

/// Port of `ParsedH265SliceHeader` (`src/h265/slice-header.ts:20`).
class ParsedH265SliceHeader {
  const ParsedH265SliceHeader({
    required this.ppsId,
    required this.sliceType,
    required this.pictureOrderCountLsb,
    required this.referencePictureSet,
    required this.randomAccess,
    required this.noOutputOfPriorPictures,
  });

  final int ppsId;

  /// One of `"I"`, `"P"`, `"B"`.
  final String sliceType;
  final int pictureOrderCountLsb;
  final H265ShortTermReferencePictureSet referencePictureSet;
  final H265RandomAccessKind? randomAccess;
  final bool noOutputOfPriorPictures;
}

/// Port of `parseH265SliceHeader` (`src/h265/slice-header.ts:29`).
ParsedH265SliceHeader parseH265SliceHeader(
  H265AnnexBNalUnit nal,
  ParsedH265Pps pps,
  ParsedH265Sps sps,
  String path,
) {
  final reader = H265RbspBitReader(nal.rbsp, path, nal.offset + 2);
  requireH265(
    reader.readBit('first_slice_segment_in_pic_flag'),
    path,
    'the production HEVC profile requires one slice segment per picture',
  );
  final randomAccess = _randomAccessKind(nal.type);
  final noOutputOfPriorPictures = randomAccess == null
      ? false
      : reader.readBit('no_output_of_prior_pics_flag');
  final ppsId = reader.readUnsignedExpGolomb('slice_pic_parameter_set_id', 63);
  requireH265(ppsId == pps.id, path, 'slice references an unexpected PPS');
  for (var index = 0; index < pps.numExtraSliceHeaderBits; index += 1) {
    reader.readBit('slice_reserved_flag[$index]');
  }
  final rawSliceType = reader.readUnsignedExpGolomb('slice_type', 2);
  final sliceType = rawSliceType == 2
      ? 'I'
      : rawSliceType == 1
          ? 'P'
          : 'B';
  requireH265(
    randomAccess == null || sliceType == 'I',
    path,
    'an HEVC random-access picture must be intra-coded',
  );
  if (pps.outputFlagPresent) reader.readBit('pic_output_flag');

  var pictureOrderCountLsb = 0;
  H265ShortTermReferencePictureSet referencePictureSet =
      const H265ShortTermReferencePictureSet(pictures: []);
  if (!isH265IdrNalType(nal.type)) {
    pictureOrderCountLsb = reader.readBits(
      sps.log2MaxPictureOrderCountLsb,
      'slice_pic_order_cnt_lsb',
    );
    final fromSps = reader.readBit('short_term_ref_pic_set_sps_flag');
    if (fromSps) {
      requireH265(
        sps.shortTermReferencePictureSets.isNotEmpty,
        path,
        'slice selects an absent SPS reference-picture set',
      );
      final indexWidth = _ceilLog2(sps.shortTermReferencePictureSets.length);
      final index = indexWidth == 0
          ? 0
          : reader.readBits(indexWidth, 'short_term_ref_pic_set_idx');
      final selected =
          index >= 0 && index < sps.shortTermReferencePictureSets.length
              ? sps.shortTermReferencePictureSets[index]
              : null;
      requireH265(selected != null, path, 'slice RPS index is out of range');
      referencePictureSet = selected!;
    } else {
      referencePictureSet = parseH265ShortTermReferencePictureSet(
        reader,
        sps.shortTermReferencePictureSets.length,
        sps.shortTermReferencePictureSets.length,
        sps.shortTermReferencePictureSets.toList(),
      );
    }
    requireH265(
      !sps.longTermReferencePicturesPresent,
      path,
      'long-term references are outside the production HEVC profile',
    );
    if (sps.temporalMvpEnabled) {
      reader.readBit('slice_temporal_mvp_enabled_flag');
    }
  }
  requireH265(
    reader.bitsRemaining >= 8,
    path,
    'slice header or coded slice payload is truncated',
  );
  return ParsedH265SliceHeader(
    ppsId: ppsId,
    sliceType: sliceType,
    pictureOrderCountLsb: pictureOrderCountLsb,
    referencePictureSet: referencePictureSet,
    randomAccess: randomAccess,
    noOutputOfPriorPictures: noOutputOfPriorPictures,
  );
}

H265RandomAccessKind? _randomAccessKind(int type) {
  if (!isH265RandomAccessNalType(type)) return null;
  if (type == H265_NAL_BLA_W_LP ||
      type == H265_NAL_BLA_W_RADL ||
      type == H265_NAL_BLA_N_LP) {
    return 'bla';
  }
  if (type == H265_NAL_CRA_NUT) return 'cra';
  return 'idr';
}

/// Port of `ceilLog2` (`src/h265/slice-header.ts:123`).
///
/// For `value > 1`, `Math.ceil(Math.log2(value))` equals `(value - 1)`'s bit
/// length; computed here with integer arithmetic to avoid float rounding.
int _ceilLog2(int value) {
  return value <= 1 ? 0 : (value - 1).bitLength;
}
