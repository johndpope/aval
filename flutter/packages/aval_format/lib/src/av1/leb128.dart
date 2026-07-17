/// Canonical unsigned LEB128 reading/writing bounded to safe integers.
///
/// Dart port of `packages/format/src/av1/leb128.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';

class Av1Leb128 {
  const Av1Leb128({required this.value, required this.length});

  final int value;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is Av1Leb128 && other.value == value && other.length == length;

  @override
  int get hashCode => Object.hash(value, length);
}

/// Read a canonical unsigned LEB128 value bounded to safe integers.
Av1Leb128 readAv1Leb128(Uint8List bytes, int offset,
    [String path = 'av1.leb128']) {
  if (offset < 0 || offset > maxSafeInteger) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AV1 LEB128 input is invalid',
      FormatErrorDetails(path: path),
    );
  }
  var value = 0;
  var length = 0;
  for (; length < 8; length += 1) {
    if (offset + length >= bytes.length) {
      throw FormatError(
        FormatErrorCode.profileInvalid,
        'AV1 LEB128 is truncated',
        FormatErrorDetails(path: path, offset: offset + length),
      );
    }
    final byte = bytes[offset + length];
    value |= (byte & 0x7f) << (length * 7);
    if ((byte & 0x80) == 0) {
      final byteLength = length + 1;
      if (byteLength > 1 && value < (1 << ((byteLength - 1) * 7))) {
        throw FormatError(
          FormatErrorCode.profileInvalid,
          'AV1 LEB128 is non-canonical',
          FormatErrorDetails(path: path, offset: offset),
        );
      }
      if (value > maxSafeInteger) {
        throw FormatError(
          FormatErrorCode.profileInvalid,
          'AV1 LEB128 is unsafe',
          FormatErrorDetails(path: path, offset: offset),
        );
      }
      return Av1Leb128(value: value, length: byteLength);
    }
  }
  throw FormatError(
    FormatErrorCode.profileInvalid,
    'AV1 LEB128 exceeds eight bytes',
    FormatErrorDetails(path: path, offset: offset),
  );
}

Uint8List encodeAv1Leb128(int value) {
  if (value < 0 || value > maxSafeInteger) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AV1 LEB128 value is invalid',
    );
  }
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    bytes.add(byte);
  } while (remaining != 0);
  return Uint8List.fromList(bytes);
}
