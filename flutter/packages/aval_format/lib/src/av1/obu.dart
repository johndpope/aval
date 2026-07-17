/// AV1 low-overhead OBU parsing into owned payloads.
///
/// Dart port of `packages/format/src/av1/obu.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';
import 'leb128.dart';

const int av1ObuSequenceHeader = 1;
const int av1ObuTemporalDelimiter = 2;
const int av1ObuFrameHeader = 3;
const int av1ObuTileGroup = 4;
const int av1ObuMetadata = 5;
const int av1ObuFrame = 6;
const int av1ObuRedundantFrameHeader = 7;
const int av1ObuTileList = 8;
const int av1ObuPadding = 15;

const Set<int> _allowedObuTypes = {
  av1ObuSequenceHeader,
  av1ObuTemporalDelimiter,
  av1ObuFrameHeader,
  av1ObuTileGroup,
  av1ObuMetadata,
  av1ObuFrame,
  av1ObuRedundantFrameHeader,
  av1ObuPadding,
};

class Av1Obu {
  const Av1Obu({
    required this.type,
    required this.temporalId,
    required this.spatialId,
    required this.payload,
  });

  final int type;
  final int temporalId;
  final int spatialId;
  final Uint8List payload;

  @override
  bool operator ==(Object other) {
    if (other is! Av1Obu) return false;
    if (other.type != type ||
        other.temporalId != temporalId ||
        other.spatialId != spatialId ||
        other.payload.length != payload.length) {
      return false;
    }
    for (var index = 0; index < payload.length; index += 1) {
      if (other.payload[index] != payload[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(type, temporalId, spatialId, Object.hashAll(payload));
}

/// Parse one low-overhead temporal unit into owned OBU payloads.
List<Av1Obu> parseAv1LowOverheadObus(Uint8List bytes,
    [String path = 'av1.temporalUnit']) {
  _requireAv1(bytes.isNotEmpty, path, 'temporal unit is empty');
  final output = <Av1Obu>[];
  var cursor = 0;
  while (cursor < bytes.length) {
    final headerOffset = cursor;
    _requireAv1(cursor < bytes.length, path, 'OBU header is truncated', cursor);
    final header = bytes[cursor];
    cursor += 1;
    _requireAv1((header & 0x80) == 0, path, 'obu_forbidden_bit must be zero',
        headerOffset);
    final type = (header >> 3) & 0x0f;
    final extension = (header & 0x04) != 0;
    final hasSize = (header & 0x02) != 0;
    _requireAv1((header & 0x01) == 0, path, 'OBU reserved bit must be zero',
        headerOffset);
    _requireAv1(hasSize, path, 'low-overhead OBU requires a size field',
        headerOffset);
    _requireAv1(_allowedObuTypes.contains(type), path,
        'OBU type $type is unsupported', headerOffset);
    _requireAv1(type != av1ObuTileList, path, 'tile-list OBU is unsupported',
        headerOffset);

    var temporalId = 0;
    var spatialId = 0;
    if (extension) {
      _requireAv1(cursor < bytes.length, path, 'OBU extension is truncated',
          cursor);
      final extensionByte = bytes[cursor];
      cursor += 1;
      temporalId = extensionByte >> 5;
      spatialId = (extensionByte >> 3) & 0x03;
      _requireAv1((extensionByte & 0x07) == 0, path,
          'OBU extension reserved bits must be zero', cursor - 1);
      _requireAv1(temporalId == 0 && spatialId == 0, path,
          'scalable AV1 layers are unsupported', cursor - 1);
    }

    final size = readAv1Leb128(bytes, cursor, '$path.obuSize');
    cursor += size.length;
    _requireAv1(size.value <= bytes.length - cursor, path,
        'OBU payload is truncated', cursor);
    final payload = bytes.sublist(cursor, cursor + size.value);
    cursor += size.value;
    if (type == av1ObuTemporalDelimiter) {
      _requireAv1(payload.isEmpty, path,
          'temporal delimiter payload must be empty', headerOffset);
    }
    output.add(Av1Obu(
      type: type,
      temporalId: temporalId,
      spatialId: spatialId,
      payload: payload,
    ));
  }
  return output;
}

void _requireAv1(bool condition, String path, String message, [int? offset]) {
  if (!condition) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AV1 $message',
      FormatErrorDetails(path: path, offset: offset),
    );
  }
}
