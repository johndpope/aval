/// AV1 frame-header prefix parsing (random access / display semantics).
///
/// Dart port of `packages/format/src/av1/frame-header.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';
import 'bit_reader.dart';
import 'sequence_header.dart';

/// AV1 frame type, modeled as a string-literal union in the TypeScript source.
typedef Av1FrameType = String;

class Av1FrameHeaderPrefix {
  const Av1FrameHeaderPrefix({
    required this.frameType,
    required this.key,
    required this.randomAccess,
    required this.showFrame,
    required this.showExistingFrame,
    required this.displayedFrameCount,
  });

  final Av1FrameType frameType;
  final bool key;
  final bool randomAccess;
  final bool showFrame;
  final bool showExistingFrame;
  final int displayedFrameCount;

  @override
  bool operator ==(Object other) =>
      other is Av1FrameHeaderPrefix &&
      other.frameType == frameType &&
      other.key == key &&
      other.randomAccess == randomAccess &&
      other.showFrame == showFrame &&
      other.showExistingFrame == showExistingFrame &&
      other.displayedFrameCount == displayedFrameCount;

  @override
  int get hashCode => Object.hash(frameType, key, randomAccess, showFrame,
      showExistingFrame, displayedFrameCount);
}

/// Parse the frame-header prefix that determines random access and display.
Av1FrameHeaderPrefix parseAv1FrameHeaderPrefix(
  Uint8List payload,
  Av1SequenceHeader sequence, [
  String path = 'av1.frameHeader',
]) {
  if (payload.isEmpty) {
    _invalid('frame header is empty', path);
  }
  if (sequence.reducedStillPictureHeader) {
    return const Av1FrameHeaderPrefix(
      frameType: 'key',
      key: true,
      randomAccess: true,
      showFrame: true,
      showExistingFrame: false,
      displayedFrameCount: 1,
    );
  }

  final reader = Av1BitReader(payload, path);
  final showExistingFrame = reader.readBit('show_existing_frame');
  if (showExistingFrame) {
    reader.readBits(3, 'frame_to_show_map_idx');
    return const Av1FrameHeaderPrefix(
      frameType: 'show-existing',
      key: false,
      randomAccess: false,
      showFrame: true,
      showExistingFrame: true,
      displayedFrameCount: 1,
    );
  }

  final rawFrameType = reader.readBits(2, 'frame_type');
  const frameTypes = ['key', 'inter', 'intra-only', 'switch'];
  final frameType =
      rawFrameType < frameTypes.length ? frameTypes[rawFrameType] : null;
  if (frameType == null) _invalid('frame type is invalid', path);
  final showFrame = reader.readBit('show_frame');
  if (!showFrame) reader.readBit('showable_frame');
  return Av1FrameHeaderPrefix(
    frameType: frameType,
    key: frameType == 'key',
    randomAccess: frameType == 'key' && showFrame,
    showFrame: showFrame,
    showExistingFrame: false,
    displayedFrameCount: showFrame ? 1 : 0,
  );
}

Never _invalid(String message, String path) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    'AV1 $message',
    FormatErrorDetails(path: path),
  );
}
