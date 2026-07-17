/// VP9 profile-0 rendition inspection preserving hidden/reference frames.
///
/// Dart port of `packages/format/src/vp9/inspector.ts`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';
import 'codec.dart';
import 'frame_header.dart';
import 'superframe.dart';

class Vp9PacketInput {
  const Vp9PacketInput({
    required this.bytes,
    required this.key,
    required this.timestamp,
  });

  final Uint8List bytes;
  final bool key;
  final int timestamp;
}

class Vp9UnitInput {
  const Vp9UnitInput({
    required this.id,
    required this.packets,
    required this.expectedDisplayedFrames,
  });

  final String id;
  final List<Vp9PacketInput> packets;
  final int expectedDisplayedFrames;
}

class Vp9RenditionInspectionInput {
  const Vp9RenditionInspectionInput({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.averageBitrate,
    required this.units,
  });

  final int width;
  final int height;
  final ({int numerator, int denominator}) frameRate;
  final int averageBitrate;
  final List<Vp9UnitInput> units;
}

class Vp9PacketInspection {
  const Vp9PacketInspection({
    required this.timestamp,
    required this.chunkType,
    required this.codedFrames,
    required this.displayedFrameCount,
  });

  final int timestamp;
  final String chunkType;
  final List<Vp9FrameHeader> codedFrames;
  final int displayedFrameCount;
}

class Vp9UnitInspection {
  const Vp9UnitInspection({
    required this.id,
    required this.packets,
    required this.displayedFrameCount,
  });

  final String id;
  final List<Vp9PacketInspection> packets;
  final int displayedFrameCount;
}

class Vp9RenditionInspection {
  const Vp9RenditionInspection({
    required this.codec,
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.units,
  });

  final Vp9Codec codec;
  final int width;
  final int height;
  final int bitDepth;
  final List<Vp9UnitInspection> units;
}

/// Inspect profile-0 VP9 packets while preserving hidden/reference frames.
Vp9RenditionInspection inspectVp9Rendition(Vp9RenditionInspectionInput input) {
  _requirePositiveInteger(input.width, 'width');
  _requirePositiveInteger(input.height, 'height');
  _requirePositiveInteger(input.frameRate.numerator, 'frameRate.numerator');
  _requirePositiveInteger(input.frameRate.denominator, 'frameRate.denominator');
  _requirePositiveInteger(input.averageBitrate, 'averageBitrate');
  if (input.units.isEmpty) {
    _invalid('VP9 rendition requires at least one unit', 'units');
  }

  final unitIds = <String>{};
  final units = <Vp9UnitInspection>[];
  var maximumCodedFramesPerDisplayedFrame = 1.0;
  for (var unitIndex = 0; unitIndex < input.units.length; unitIndex += 1) {
    final unit = input.units[unitIndex];
    final unitPath = 'units[$unitIndex]';
    if (unit.id.isEmpty) {
      _invalid('VP9 unit id is invalid', '$unitPath.id');
    }
    if (unitIds.contains(unit.id)) {
      _invalid('VP9 unit id is duplicated', '$unitPath.id');
    }
    unitIds.add(unit.id);
    _requirePositiveInteger(
        unit.expectedDisplayedFrames, '$unitPath.expectedDisplayedFrames');
    if (unit.packets.isEmpty) {
      _invalid('VP9 unit requires packets', '$unitPath.packets');
    }

    final packets = <Vp9PacketInspection>[];
    var displayedFrameCount = 0;
    var codedFrameCount = 0;
    for (var packetIndex = 0;
        packetIndex < unit.packets.length;
        packetIndex += 1) {
      final packet = unit.packets[packetIndex];
      final packetPath = '$unitPath.packets[$packetIndex]';
      if (packet.timestamp < 0 || packet.timestamp > maxSafeInteger) {
        _invalid('VP9 packet timestamp is invalid', '$packetPath.timestamp');
      }
      final splitFrames =
          splitVp9Superframe(packet.bytes, '$packetPath.bytes');
      final codedFrames = <Vp9FrameHeader>[];
      for (var frameIndex = 0; frameIndex < splitFrames.length; frameIndex += 1) {
        codedFrames.add(parseVp9FrameHeader(
          splitFrames[frameIndex],
          '$packetPath.codedFrames[$frameIndex]',
        ));
      }
      final packetDisplayedFrames = codedFrames.fold<int>(
        0,
        (total, frame) => total + frame.displayedFrameCount,
      );
      if (codedFrames.isEmpty) {
        _invalid('VP9 packet contains no coded frames', packetPath);
      }
      final first = codedFrames[0];
      if (packetIndex == 0 && !first.key) {
        _invalid('VP9 unit must start with a key frame', packetPath);
      }
      if (packet.key != first.key) {
        _invalid('VP9 chunk key assertion disagrees with the bitstream',
            '$packetPath.key');
      }
      displayedFrameCount += packetDisplayedFrames;
      codedFrameCount += codedFrames.length;
      packets.add(Vp9PacketInspection(
        timestamp: packet.timestamp,
        chunkType: first.key ? 'key' : 'delta',
        codedFrames: codedFrames,
        displayedFrameCount: packetDisplayedFrames,
      ));
    }
    if (displayedFrameCount != unit.expectedDisplayedFrames) {
      _invalid('VP9 displayed frame count disagrees with the authored unit',
          unitPath);
    }
    maximumCodedFramesPerDisplayedFrame = math.max(
      maximumCodedFramesPerDisplayedFrame,
      codedFrameCount / displayedFrameCount,
    );
    units.add(Vp9UnitInspection(
      id: unit.id,
      packets: packets,
      displayedFrameCount: displayedFrameCount,
    ));
  }

  final displayFramesPerSecond =
      input.frameRate.numerator / input.frameRate.denominator;
  final codec = deriveVp9Codec(DeriveVp9CodecInput(
    width: input.width,
    height: input.height,
    codedFramesPerSecond:
        displayFramesPerSecond * maximumCodedFramesPerDisplayedFrame,
    averageBitrate: input.averageBitrate,
  ));
  return Vp9RenditionInspection(
    codec: codec,
    width: input.width,
    height: input.height,
    bitDepth: 8,
    units: units,
  );
}

void _requirePositiveInteger(int value, String path) {
  if (value <= 0 || value > maxSafeInteger) {
    _invalid('VP9 value must be a positive safe integer', path);
  }
}

Never _invalid(String message, String path) {
  throw FormatError(
    FormatErrorCode.profileInvalid,
    message,
    FormatErrorDetails(path: path),
  );
}
