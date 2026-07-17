/// VP9 uncompressed frame-header parsing for the AVAL profile-0 subset.
///
/// Dart port of `packages/format/src/vp9/frame-header.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';
import 'bit_reader.dart';

const int _vp9FrameMarker = 2;
const int _vp9SyncCode = 0x498342;
const int _vp9ColorSpaceBt709 = 2;

class Vp9ColorConfig {
  const Vp9ColorConfig({
    this.bitDepth = 8,
    this.chromaSubsampling = 1,
    this.colorPrimaries = 1,
    this.transferCharacteristics = 1,
    this.matrixCoefficients = 1,
    this.fullRange = false,
  });

  final int bitDepth;
  final int chromaSubsampling;
  final int colorPrimaries;
  final int transferCharacteristics;
  final int matrixCoefficients;
  final bool fullRange;

  @override
  bool operator ==(Object other) =>
      other is Vp9ColorConfig &&
      other.bitDepth == bitDepth &&
      other.chromaSubsampling == chromaSubsampling &&
      other.colorPrimaries == colorPrimaries &&
      other.transferCharacteristics == transferCharacteristics &&
      other.matrixCoefficients == matrixCoefficients &&
      other.fullRange == fullRange;

  @override
  int get hashCode => Object.hash(bitDepth, chromaSubsampling, colorPrimaries,
      transferCharacteristics, matrixCoefficients, fullRange);
}

class Vp9FrameHeader {
  const Vp9FrameHeader({
    required this.profile,
    required this.key,
    required this.showFrame,
    required this.showExistingFrame,
    required this.displayedFrameCount,
    required this.errorResilient,
    this.width,
    this.height,
    this.renderWidth,
    this.renderHeight,
    this.color,
  });

  final int profile;
  final bool key;
  final bool showFrame;
  final bool showExistingFrame;
  final int displayedFrameCount;
  final bool errorResilient;
  final int? width;
  final int? height;
  final int? renderWidth;
  final int? renderHeight;
  final Vp9ColorConfig? color;

  @override
  bool operator ==(Object other) =>
      other is Vp9FrameHeader &&
      other.profile == profile &&
      other.key == key &&
      other.showFrame == showFrame &&
      other.showExistingFrame == showExistingFrame &&
      other.displayedFrameCount == displayedFrameCount &&
      other.errorResilient == errorResilient &&
      other.width == width &&
      other.height == height &&
      other.renderWidth == renderWidth &&
      other.renderHeight == renderHeight &&
      other.color == color;

  @override
  int get hashCode => Object.hash(profile, key, showFrame, showExistingFrame,
      displayedFrameCount, errorResilient, width, height, renderWidth,
      renderHeight, color);
}

/// Parse the bounded VP9 uncompressed header needed by the AVAL profile.
Vp9FrameHeader parseVp9FrameHeader(Uint8List bytes, [String path = 'vp9.frame']) {
  if (bytes.isEmpty) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'VP9 frame is empty',
      FormatErrorDetails(path: path),
    );
  }
  final reader = Vp9BitReader(bytes, path);
  _requireVp9(
    reader.readBits(2, 'frame_marker') == _vp9FrameMarker,
    path,
    'frame_marker must equal 2',
  );
  final profile = (reader.readBit('profile_low') ? 1 : 0) |
      ((reader.readBit('profile_high') ? 1 : 0) << 1);
  if (profile == 3) {
    _requireVp9(!reader.readBit('reserved_zero'), path,
        'reserved profile bit must be zero');
  }
  _requireVp9(profile == 0, path, 'only 8-bit 4:2:0 profile 0 is supported');

  final showExistingFrame = reader.readBit('show_existing_frame');
  if (showExistingFrame) {
    reader.readBits(3, 'frame_to_show_map_idx');
    return const Vp9FrameHeader(
      profile: 0,
      key: false,
      showFrame: true,
      showExistingFrame: true,
      displayedFrameCount: 1,
      errorResilient: false,
    );
  }

  final key = !reader.readBit('frame_type');
  final showFrame = reader.readBit('show_frame');
  final errorResilient = reader.readBit('error_resilient_mode');
  if (!key) {
    return Vp9FrameHeader(
      profile: 0,
      key: key,
      showFrame: showFrame,
      showExistingFrame: false,
      displayedFrameCount: showFrame ? 1 : 0,
      errorResilient: errorResilient,
    );
  }

  _requireVp9(
    reader.readBits(24, 'frame_sync_code') == _vp9SyncCode,
    path,
    'key frame sync code is invalid',
  );
  final colorSpace = reader.readBits(3, 'color_space');
  _requireVp9(
    colorSpace == _vp9ColorSpaceBt709,
    path,
    'key frame must signal BT.709 color space',
  );
  _requireVp9(!reader.readBit('color_range'), path,
      'key frame must use limited range');

  final width = reader.readBits(16, 'frame_width_minus_1') + 1;
  final height = reader.readBits(16, 'frame_height_minus_1') + 1;
  _requireVp9(width > 0 && height > 0, path, 'key frame dimensions are invalid');
  final renderAndFrameSizeDifferent =
      reader.readBit('render_and_frame_size_different');
  final renderWidth = renderAndFrameSizeDifferent
      ? reader.readBits(16, 'render_width_minus_1') + 1
      : width;
  final renderHeight = renderAndFrameSizeDifferent
      ? reader.readBits(16, 'render_height_minus_1') + 1
      : height;

  return Vp9FrameHeader(
    profile: 0,
    key: key,
    showFrame: showFrame,
    showExistingFrame: false,
    displayedFrameCount: showFrame ? 1 : 0,
    errorResilient: errorResilient,
    width: width,
    height: height,
    renderWidth: renderWidth,
    renderHeight: renderHeight,
    color: const Vp9ColorConfig(),
  );
}

void _requireVp9(bool condition, String path, String message) {
  if (!condition) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'VP9 $message',
      FormatErrorDetails(path: path),
    );
  }
}
