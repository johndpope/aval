/// AV1 single-layer Main-profile sequence-header parsing.
///
/// Dart port of `packages/format/src/av1/sequence-header.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';
import 'bit_reader.dart';

class Av1SequenceHeader {
  const Av1SequenceHeader({
    required this.profile,
    required this.level,
    required this.tier,
    required this.bitDepth,
    required this.maxWidth,
    required this.maxHeight,
    required this.monochrome,
    required this.subsamplingX,
    required this.subsamplingY,
    required this.chromaSamplePosition,
    required this.colorPrimaries,
    required this.transferCharacteristics,
    required this.matrixCoefficients,
    required this.fullRange,
    required this.reducedStillPictureHeader,
    required this.frameIdNumbersPresent,
    required this.filmGrainParamsPresent,
  });

  final int profile;
  final int level;
  final String tier;
  final int bitDepth;
  final int maxWidth;
  final int maxHeight;
  final bool monochrome;
  final int subsamplingX;
  final int subsamplingY;
  final int chromaSamplePosition;
  final int colorPrimaries;
  final int transferCharacteristics;
  final int matrixCoefficients;
  final bool fullRange;
  final bool reducedStillPictureHeader;
  final bool frameIdNumbersPresent;
  final bool filmGrainParamsPresent;

  @override
  bool operator ==(Object other) =>
      other is Av1SequenceHeader &&
      other.profile == profile &&
      other.level == level &&
      other.tier == tier &&
      other.bitDepth == bitDepth &&
      other.maxWidth == maxWidth &&
      other.maxHeight == maxHeight &&
      other.monochrome == monochrome &&
      other.subsamplingX == subsamplingX &&
      other.subsamplingY == subsamplingY &&
      other.chromaSamplePosition == chromaSamplePosition &&
      other.colorPrimaries == colorPrimaries &&
      other.transferCharacteristics == transferCharacteristics &&
      other.matrixCoefficients == matrixCoefficients &&
      other.fullRange == fullRange &&
      other.reducedStillPictureHeader == reducedStillPictureHeader &&
      other.frameIdNumbersPresent == frameIdNumbersPresent &&
      other.filmGrainParamsPresent == filmGrainParamsPresent;

  @override
  int get hashCode => Object.hashAll([
        profile,
        level,
        tier,
        bitDepth,
        maxWidth,
        maxHeight,
        monochrome,
        subsamplingX,
        subsamplingY,
        chromaSamplePosition,
        colorPrimaries,
        transferCharacteristics,
        matrixCoefficients,
        fullRange,
        reducedStillPictureHeader,
        frameIdNumbersPresent,
        filmGrainParamsPresent,
      ]);
}

/// Parse the single-layer Main-profile sequence-header subset emitted by AVAL.
Av1SequenceHeader parseAv1SequenceHeader(Uint8List payload,
    [String path = 'av1.sequenceHeader']) {
  if (payload.isEmpty) {
    _invalid('sequence header is empty', path);
  }
  final reader = Av1BitReader(payload, path);
  final profile = reader.readBits(3, 'seq_profile');
  _requireAv1(profile == 0, path, 'only Main profile is supported');
  final stillPicture = reader.readBit('still_picture');
  final reducedStillPictureHeader =
      reader.readBit('reduced_still_picture_header');
  _requireAv1(!reducedStillPictureHeader || stillPicture, path,
      'reduced header requires still_picture');

  int level;
  var tier = 'M';
  if (reducedStillPictureHeader) {
    level = reader.readBits(5, 'seq_level_idx_0');
  } else {
    _requireAv1(!reader.readBit('timing_info_present_flag'), path,
        'timing info is unsupported');
    final initialDisplayDelayPresent =
        reader.readBit('initial_display_delay_present_flag');
    _requireAv1(
      reader.readBits(5, 'operating_points_cnt_minus_1') == 0,
      path,
      'multiple operating points are unsupported',
    );
    _requireAv1(reader.readBits(12, 'operating_point_idc_0') == 0, path,
        'scalable operating points are unsupported');
    level = reader.readBits(5, 'seq_level_idx_0');
    if (level > 7) tier = reader.readBit('seq_tier_0') ? 'H' : 'M';
    if (initialDisplayDelayPresent) {
      final present =
          reader.readBit('initial_display_delay_present_for_this_op_0');
      if (present) reader.readBits(4, 'initial_display_delay_minus_1_0');
    }
  }

  final widthBits = reader.readBits(4, 'frame_width_bits_minus_1') + 1;
  final heightBits = reader.readBits(4, 'frame_height_bits_minus_1') + 1;
  final maxWidth = reader.readBits(widthBits, 'max_frame_width_minus_1') + 1;
  final maxHeight = reader.readBits(heightBits, 'max_frame_height_minus_1') + 1;
  var frameIdNumbersPresent = false;
  if (!reducedStillPictureHeader) {
    frameIdNumbersPresent = reader.readBit('frame_id_numbers_present_flag');
    if (frameIdNumbersPresent) {
      reader.readBits(4, 'delta_frame_id_length_minus_2');
      reader.readBits(3, 'additional_frame_id_length_minus_1');
    }
  }

  reader.readBit('use_128x128_superblock');
  reader.readBit('enable_filter_intra');
  reader.readBit('enable_intra_edge_filter');
  if (!reducedStillPictureHeader) {
    reader.readBit('enable_interintra_compound');
    reader.readBit('enable_masked_compound');
    reader.readBit('enable_warped_motion');
    reader.readBit('enable_dual_filter');
    final enableOrderHint = reader.readBit('enable_order_hint');
    if (enableOrderHint) {
      reader.readBit('enable_jnt_comp');
      reader.readBit('enable_ref_frame_mvs');
    }
    final chooseScreenContentTools =
        reader.readBit('seq_choose_screen_content_tools');
    final forceScreenContentTools = chooseScreenContentTools
        ? 2
        : (reader.readBit('seq_force_screen_content_tools') ? 1 : 0);
    if (forceScreenContentTools > 0) {
      final chooseIntegerMv = reader.readBit('seq_choose_integer_mv');
      if (!chooseIntegerMv) reader.readBit('seq_force_integer_mv');
    }
    if (enableOrderHint) reader.readBits(3, 'order_hint_bits_minus_1');
  }
  reader.readBit('enable_superres');
  reader.readBit('enable_cdef');
  reader.readBit('enable_restoration');

  final highBitdepth = reader.readBit('high_bitdepth');
  final bitDepth = highBitdepth ? 10 : 8;
  final monochrome = reader.readBit('mono_chrome');
  _requireAv1(!monochrome, path, 'monochrome output is unsupported');
  final colorDescriptionPresent =
      reader.readBit('color_description_present_flag');
  _requireAv1(colorDescriptionPresent, path,
      'explicit BT.709 color description is required');
  final colorPrimaries = reader.readBits(8, 'color_primaries');
  final transferCharacteristics =
      reader.readBits(8, 'transfer_characteristics');
  final matrixCoefficients = reader.readBits(8, 'matrix_coefficients');
  _requireAv1(
    colorPrimaries == 1 &&
        transferCharacteristics == 1 &&
        matrixCoefficients == 1,
    path,
    'color description must be BT.709',
  );
  _requireAv1(!reader.readBit('color_range'), path,
      'limited color range is required');
  final chromaSamplePosition = reader.readBits(2, 'chroma_sample_position');
  reader.readBit('separate_uv_delta_q');
  final filmGrainParamsPresent = reader.readBit('film_grain_params_present');
  reader.readTrailingBits();

  return Av1SequenceHeader(
    profile: 0,
    level: level,
    tier: tier,
    bitDepth: bitDepth,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    monochrome: false,
    subsamplingX: 1,
    subsamplingY: 1,
    chromaSamplePosition: chromaSamplePosition,
    colorPrimaries: 1,
    transferCharacteristics: 1,
    matrixCoefficients: 1,
    fullRange: false,
    reducedStillPictureHeader: reducedStillPictureHeader,
    frameIdNumbersPresent: frameIdNumbersPresent,
    filmGrainParamsPresent: filmGrainParamsPresent,
  );
}

void _requireAv1(bool condition, String path, String message) {
  if (!condition) _invalid(message, path);
}

Never _invalid(String message, String path) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    'AV1 $message',
    FormatErrorDetails(path: path),
  );
}
