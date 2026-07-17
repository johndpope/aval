/// AV1 low-overhead temporal-unit inspection preserving hidden frames.
///
/// Dart port of `packages/format/src/av1/inspector.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';
import 'codec.dart';
import 'frame_header.dart';
import 'obu.dart';
import 'sequence_header.dart';

class Av1ChunkInput {
  const Av1ChunkInput({
    required this.bytes,
    required this.key,
    required this.timestamp,
  });

  final Uint8List bytes;
  final bool key;
  final int timestamp;
}

class Av1UnitInput {
  const Av1UnitInput({
    required this.id,
    required this.chunks,
    required this.expectedDisplayedFrames,
  });

  final String id;
  final List<Av1ChunkInput> chunks;
  final int expectedDisplayedFrames;
}

class Av1RenditionInspectionInput {
  const Av1RenditionInspectionInput({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.units,
  });

  final int width;
  final int height;
  final int bitDepth;
  final List<Av1UnitInput> units;
}

class Av1ChunkInspection {
  const Av1ChunkInspection({
    required this.timestamp,
    required this.chunkType,
    required this.frames,
    required this.displayedFrameCount,
  });

  final int timestamp;
  final String chunkType;
  final List<Av1FrameHeaderPrefix> frames;
  final int displayedFrameCount;
}

class Av1UnitInspection {
  const Av1UnitInspection({
    required this.id,
    required this.chunks,
    required this.displayedFrameCount,
  });

  final String id;
  final List<Av1ChunkInspection> chunks;
  final int displayedFrameCount;
}

class Av1RenditionInspection {
  const Av1RenditionInspection({
    required this.codec,
    required this.sequence,
    required this.units,
  });

  final Av1Codec codec;
  final Av1SequenceHeader sequence;
  final List<Av1UnitInspection> units;
}

/// Inspect low-overhead AV1 temporal units, including hidden/show-existing frames.
Av1RenditionInspection inspectAv1Rendition(Av1RenditionInspectionInput input) {
  _requirePositiveInteger(input.width, 'width');
  _requirePositiveInteger(input.height, 'height');
  if (input.bitDepth != 8 && input.bitDepth != 10) {
    _invalid('bit depth is invalid', 'bitDepth');
  }
  if (input.units.isEmpty) _invalid('rendition requires units', 'units');

  Av1SequenceHeader? stableSequence;
  final unitIds = <String>{};
  final units = <Av1UnitInspection>[];
  for (var unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
    final unit = input.units[unitIndex];
    final unitPath = 'units[$unitIndex]';
    if (unit.id.isEmpty) {
      _invalid('unit id is invalid', '$unitPath.id');
    }
    if (unitIds.contains(unit.id)) {
      _invalid('unit id is duplicated', '$unitPath.id');
    }
    unitIds.add(unit.id);
    _requirePositiveInteger(
        unit.expectedDisplayedFrames, '$unitPath.expectedDisplayedFrames');
    if (unit.chunks.isEmpty) {
      _invalid('unit requires chunks', '$unitPath.chunks');
    }

    var displayedFrameCount = 0;
    final chunks = <Av1ChunkInspection>[];
    for (var chunkIndex = 0; chunkIndex < unit.chunks.length; chunkIndex += 1) {
      final chunk = unit.chunks[chunkIndex];
      final chunkPath = '$unitPath.chunks[$chunkIndex]';
      if (chunk.timestamp < 0 || chunk.timestamp > maxSafeInteger) {
        _invalid('chunk timestamp is invalid', '$chunkPath.timestamp');
      }
      final obus = parseAv1LowOverheadObus(chunk.bytes, '$chunkPath.bytes');
      for (var obuIndex = 0; obuIndex < obus.length; obuIndex += 1) {
        final obu = obus[obuIndex];
        if (obu.type != av1ObuSequenceHeader) continue;
        final sequence = parseAv1SequenceHeader(
            obu.payload, '$chunkPath.obus[$obuIndex]');
        if (stableSequence == null) {
          stableSequence = sequence;
          _validateSequence(sequence, input);
        } else if (sequence != stableSequence) {
          _invalid('sequence header changes within the rendition',
              '$chunkPath.obus[$obuIndex]');
        }
      }
      final currentSequence = stableSequence;
      if (currentSequence == null) {
        _invalid('frame data precedes the sequence header', chunkPath);
      }
      final frames = <Av1FrameHeaderPrefix>[];
      var frameIndex = 0;
      for (final obu in obus) {
        if (obu.type != av1ObuFrame && obu.type != av1ObuFrameHeader) continue;
        frames.add(parseAv1FrameHeaderPrefix(
          obu.payload,
          currentSequence,
          '$chunkPath.frames[$frameIndex]',
        ));
        frameIndex += 1;
      }
      if (frames.isEmpty) _invalid('chunk contains no frame header', chunkPath);
      final first = frames[0];
      if (chunkIndex == 0 && !first.randomAccess) {
        _invalid('unit must start at a shown key frame', chunkPath);
      }
      if (chunk.key != frames.any((frame) => frame.key)) {
        _invalid('chunk key assertion disagrees with the bitstream',
            '$chunkPath.key');
      }
      final chunkDisplayedFrames = frames.fold<int>(
        0,
        (total, frame) => total + frame.displayedFrameCount,
      );
      displayedFrameCount += chunkDisplayedFrames;
      chunks.add(Av1ChunkInspection(
        timestamp: chunk.timestamp,
        chunkType: chunk.key ? 'key' : 'delta',
        frames: frames,
        displayedFrameCount: chunkDisplayedFrames,
      ));
    }
    if (displayedFrameCount != unit.expectedDisplayedFrames) {
      _invalid('displayed frame count disagrees with the authored unit',
          unitPath);
    }
    units.add(Av1UnitInspection(
      id: unit.id,
      chunks: chunks,
      displayedFrameCount: displayedFrameCount,
    ));
  }
  final resolvedSequence = stableSequence;
  if (resolvedSequence == null) {
    _invalid('rendition has no sequence header', 'units');
  }
  return Av1RenditionInspection(
    codec: av1CodecFromSequence(resolvedSequence),
    sequence: resolvedSequence,
    units: units,
  );
}

void _validateSequence(
    Av1SequenceHeader sequence, Av1RenditionInspectionInput input) {
  if (sequence.maxWidth != input.width || sequence.maxHeight != input.height) {
    _invalid(
        'sequence dimensions disagree with the rendition', 'sequenceHeader');
  }
  if (sequence.bitDepth != input.bitDepth) {
    _invalid(
        'sequence bit depth disagrees with the rendition', 'sequenceHeader');
  }
}

void _requirePositiveInteger(int value, String path) {
  if (value <= 0 || value > maxSafeInteger) {
    _invalid('value must be a positive safe integer', path);
  }
}

Never _invalid(String message, String path) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    'AV1 $message',
    FormatErrorDetails(path: path),
  );
}
