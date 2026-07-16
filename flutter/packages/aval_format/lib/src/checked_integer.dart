/// Bounds-checked integer arithmetic and little-endian byte codecs.
///
/// Dart port of `packages/format/src/checked-integer.ts`. Dart's `int` is a
/// native 64-bit signed integer on the VM (and arbitrary precision is not
/// needed here), so `Number.isSafeInteger` bounds in the TypeScript source
/// are reproduced with explicit `<= maxSafeInteger` checks against 2^53-1 to
/// keep identical acceptance/rejection behavior byte-for-byte, even though
/// Dart ints have more native headroom than JS doubles.
library;

import 'dart:typed_data';

import 'errors.dart';

const int _uint8Max = 0xff;
const int _uint16Max = 0xffff;
const int _uint32Max = 0xffffffff;
const int maxSafeInteger = 9007199254740991; // 2^53 - 1, matches Number.MAX_SAFE_INTEGER

FormatError _integerError(String label) => FormatError(
      FormatErrorCode.integerUnsafe,
      '$label must be a nonnegative safe integer',
    );

/// Checks that [value] is a nonnegative integer within the JS safe-integer
/// range, matching `Number.isSafeInteger(value) && value >= 0`.
int checkedNonNegativeInteger(int value, [String label = 'value']) {
  if (value < 0 || value > maxSafeInteger) {
    throw _integerError(label);
  }
  return value;
}

int _checkedLimit(int limit) => checkedNonNegativeInteger(limit, 'limit');

int _enforceLimit(int value, int limit, String label) {
  if (value > _checkedLimit(limit)) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      '$label exceeds the active limit of $limit',
    );
  }
  return value;
}

int checkedAdd(
  int left,
  int right, [
  int limit = maxSafeInteger,
  String label = 'sum',
]) {
  final safeLeft = checkedNonNegativeInteger(left, '$label left operand');
  final safeRight = checkedNonNegativeInteger(right, '$label right operand');
  if (safeLeft > maxSafeInteger - safeRight) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      '$label exceeds safe integer range',
    );
  }
  return _enforceLimit(safeLeft + safeRight, limit, label);
}

int checkedMultiply(
  int left,
  int right, [
  int limit = maxSafeInteger,
  String label = 'product',
]) {
  final safeLeft = checkedNonNegativeInteger(left, '$label left operand');
  final safeRight = checkedNonNegativeInteger(right, '$label right operand');
  if (safeLeft != 0 && safeRight > (maxSafeInteger / safeLeft).floor()) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      '$label exceeds safe integer range',
    );
  }
  return _enforceLimit(safeLeft * safeRight, limit, label);
}

int align8(
  int value, [
  int limit = maxSafeInteger,
  String label = 'aligned value',
]) {
  final safeValue = checkedNonNegativeInteger(value, label);
  final remainder = safeValue % 8;
  return remainder == 0
      ? _enforceLimit(safeValue, limit, label)
      : checkedAdd(safeValue, 8 - remainder, limit, label);
}

int checkedRangeEnd(
  int offset,
  int length, [
  int limit = maxSafeInteger,
  String label = 'range end',
]) {
  return checkedAdd(offset, length, limit, label);
}

bool rangeContains(
  int outerOffset,
  int outerLength,
  int innerOffset,
  int innerLength, [
  int limit = maxSafeInteger,
]) {
  final outerEnd =
      checkedRangeEnd(outerOffset, outerLength, limit, 'outer range end');
  final innerEnd =
      checkedRangeEnd(innerOffset, innerLength, limit, 'inner range end');
  return innerOffset >= outerOffset && innerEnd <= outerEnd;
}

/// Converts a nonnegative [BigInt] into a safe-integer [int], matching the
/// TS `bigintToSafeNumber` overflow/range behavior exactly.
int bigintToSafeNumber(
  BigInt value, [
  int limit = maxSafeInteger,
  String label = 'integer',
]) {
  if (value < BigInt.zero || value > BigInt.from(maxSafeInteger)) {
    throw FormatError(
      FormatErrorCode.integerUnsafe,
      '$label exceeds safe integer range',
    );
  }
  final numberValue = value.toInt();
  return _enforceLimit(numberValue, limit, label);
}

int requireByteRange(
  Uint8List bytes,
  int offset,
  int length, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'byte range',
]) {
  try {
    final end = checkedRangeEnd(offset, length, maxSafeInteger, label);
    if (end > bytes.lengthInBytes) {
      throw FormatError(
        code,
        '$label is truncated',
        FormatErrorDetails(
          offset: offset >= 0
              ? (offset < bytes.lengthInBytes ? offset : bytes.lengthInBytes)
              : 0,
        ),
      );
    }
    return end;
  } on FormatError catch (error) {
    if (error.code == code) rethrow;
    throw FormatError(
      code,
      '$label is invalid',
      FormatErrorDetails(offset: offset >= 0 ? offset : 0),
    );
  }
}

int _checkedUnsigned(
  int value,
  int maximum,
  FormatErrorCode code,
  String label,
  int offset,
) {
  if (value < 0 || value > maximum) {
    throw FormatError(
      code,
      '$label is outside its unsigned range',
      FormatErrorDetails(offset: offset),
    );
  }
  return value;
}

int readUint8(
  Uint8List bytes,
  int offset, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint8',
]) {
  requireByteRange(bytes, offset, 1, code, label);
  return bytes[offset];
}

int readUint16LE(
  Uint8List bytes,
  int offset, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint16',
]) {
  requireByteRange(bytes, offset, 2, code, label);
  return bytes[offset] + bytes[offset + 1] * 0x100;
}

int readUint32LE(
  Uint8List bytes,
  int offset, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint32',
]) {
  requireByteRange(bytes, offset, 4, code, label);
  return bytes[offset] +
      bytes[offset + 1] * 0x100 +
      bytes[offset + 2] * 0x10000 +
      bytes[offset + 3] * 0x1000000;
}

BigInt readUint64LEBigInt(
  Uint8List bytes,
  int offset, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint64',
]) {
  requireByteRange(bytes, offset, 8, code, label);
  var result = BigInt.zero;
  for (var index = 7; index >= 0; index -= 1) {
    result = (result << 8) | BigInt.from(bytes[offset + index]);
  }
  return result;
}

int readUint64LE(
  Uint8List bytes,
  int offset, [
  int limit = maxSafeInteger,
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint64',
]) {
  final value = readUint64LEBigInt(bytes, offset, code, label);
  try {
    return bigintToSafeNumber(value, limit, label);
  } on FormatError catch (error) {
    throw FormatError(
      error.code,
      error.message,
      FormatErrorDetails(offset: offset),
    );
  }
}

void writeUint8(
  Uint8List bytes,
  int offset,
  int value, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint8',
]) {
  requireByteRange(bytes, offset, 1, code, label);
  bytes[offset] = _checkedUnsigned(value, _uint8Max, code, label, offset);
}

void writeUint16LE(
  Uint8List bytes,
  int offset,
  int value, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint16',
]) {
  requireByteRange(bytes, offset, 2, code, label);
  final checked = _checkedUnsigned(value, _uint16Max, code, label, offset);
  bytes[offset] = checked & _uint8Max;
  bytes[offset + 1] = (checked >> 8) & _uint8Max;
}

void writeUint32LE(
  Uint8List bytes,
  int offset,
  int value, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint32',
]) {
  requireByteRange(bytes, offset, 4, code, label);
  final checked = _checkedUnsigned(value, _uint32Max, code, label, offset);
  bytes[offset] = checked & _uint8Max;
  bytes[offset + 1] = (checked >> 8) & _uint8Max;
  bytes[offset + 2] = (checked >> 16) & _uint8Max;
  bytes[offset + 3] = (checked >> 24) & _uint8Max;
}

/// Accepts either an [int] or a [BigInt] value, matching the TS
/// `number | bigint` union parameter.
void writeUint64LE(
  Uint8List bytes,
  int offset,
  Object value, [
  FormatErrorCode code = FormatErrorCode.inputInvalid,
  String label = 'uint64',
]) {
  requireByteRange(bytes, offset, 8, code, label);
  BigInt checked;
  if (value is int) {
    if (value < 0) {
      throw FormatError(
        code,
        '$label must be a nonnegative safe integer',
        FormatErrorDetails(offset: offset),
      );
    }
    checked = BigInt.from(value);
  } else if (value is BigInt) {
    final uint64Max = (BigInt.one << 64) - BigInt.one;
    if (value < BigInt.zero || value > uint64Max) {
      throw FormatError(
        code,
        '$label is outside the uint64 range',
        FormatErrorDetails(offset: offset),
      );
    }
    checked = value;
  } else {
    throw FormatError(
      code,
      '$label is outside the uint64 range',
      FormatErrorDetails(offset: offset),
    );
  }

  for (var index = 0; index < 8; index += 1) {
    bytes[offset + index] = (checked & BigInt.from(0xff)).toInt();
    checked = checked >> 8;
  }
}
