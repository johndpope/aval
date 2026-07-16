/// Deterministic byte-stable fixed-point iteration runner.
///
/// Dart port of `packages/format/src/writer-fixed-point.ts`.
library;

import 'dart:typed_data';

import 'errors.dart';

class ByteFixedPointStep<TValue, TResult> {
  const ByteFixedPointStep({required this.value, required this.bytes, required this.result});

  final TValue value;
  final Uint8List bytes;
  final TResult result;
}

class ByteFixedPointResult<TValue, TResult> extends ByteFixedPointStep<TValue, TResult> {
  const ByteFixedPointResult({
    required super.value,
    required super.bytes,
    required super.result,
    required this.iterations,
  });

  final int iterations;
}

/// Internal deterministic fixed-point runner with an injectable test seam.
ByteFixedPointResult<TValue, TResult> resolveByteStableFixedPoint<TValue, TResult>(
  TValue initialValue,
  Uint8List initialBytes,
  int maximumIterations,
  ByteFixedPointStep<TValue, TResult> Function(TValue value, Uint8List bytes) advance,
) {
  if (maximumIterations < 1) {
    throw FormatError(
      FormatErrorCode.writerInvalid,
      'fixed-point iteration limit must be a positive safe integer',
    );
  }
  var value = initialValue;
  var bytes = initialBytes;
  for (var iteration = 1; iteration <= maximumIterations; iteration += 1) {
    final next = advance(value, bytes);
    if (_equalBytes(bytes, next.bytes)) {
      return ByteFixedPointResult(
        value: next.value,
        bytes: next.bytes,
        result: next.result,
        iterations: iteration,
      );
    }
    value = next.value;
    bytes = next.bytes;
  }
  throw FormatError(
    FormatErrorCode.writerNonconvergent,
    'canonical layout did not converge in $maximumIterations iterations',
  );
}

bool _equalBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
