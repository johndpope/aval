/// VP9 superframe splitting into owned coded frames.
///
/// Dart port of `packages/format/src/vp9/superframe.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';

const int _superframeMarkerMask = 0xe0;
const int _superframeMarker = 0xc0;

/// Split a VP9 packet into owned coded frames, including hidden alt-ref frames.
List<Uint8List> splitVp9Superframe(Uint8List bytes, [String path = 'vp9']) {
  _requireVp9(bytes.isNotEmpty, path, 'packet is empty');
  final marker = bytes[bytes.length - 1];
  if ((marker & _superframeMarkerMask) != _superframeMarker) {
    return [Uint8List.fromList(bytes)];
  }

  final frameCount = (marker & 0x07) + 1;
  final magnitude = ((marker >> 3) & 0x03) + 1;
  final indexBytes = 2 + frameCount * magnitude;
  _requireVp9(bytes.length > indexBytes, path, 'superframe index is truncated');
  final indexStart = bytes.length - indexBytes;
  _requireVp9(bytes[indexStart] == marker, path, 'superframe markers disagree');

  final sizes = <int>[];
  var cursor = indexStart + 1;
  var payloadBytes = 0;
  for (var frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
    var size = 0;
    var multiplier = 1;
    for (var byteIndex = 0; byteIndex < magnitude; byteIndex += 1) {
      _requireVp9(cursor < bytes.length, path, 'superframe size is truncated');
      final byte = bytes[cursor];
      size += byte * multiplier;
      multiplier *= 256;
      cursor += 1;
    }
    _requireVp9(size > 0, path, 'superframe contains an empty coded frame');
    _requireVp9(
      payloadBytes + size <= maxSafeInteger,
      path,
      'superframe payload size is unsafe',
    );
    payloadBytes += size;
    sizes.add(size);
  }
  _requireVp9(payloadBytes == indexStart, path,
      'superframe sizes do not cover the payload');

  final frames = <Uint8List>[];
  cursor = 0;
  for (final size in sizes) {
    frames.add(bytes.sublist(cursor, cursor + size));
    cursor += size;
  }
  return frames;
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
