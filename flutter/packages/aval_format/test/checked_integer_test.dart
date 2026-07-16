// Dart port of packages/format/test/checked-integer.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/checked_integer.dart';
import 'package:aval_format/src/constants.dart';
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show FormatOptions;
import 'package:test/test.dart';

FormatError _expectFormatError(dynamic Function() operation, FormatErrorCode code) {
  try {
    operation();
  } on FormatError catch (error) {
    expect(error.code, code);
    return error;
  }
  fail('expected operation to throw');
}

void main() {
  group('checked integer arithmetic', () {
    test('accepts zero and the largest safe integer', () {
      expect(checkedNonNegativeInteger(0), 0);
      expect(checkedNonNegativeInteger(maxSafeInteger), maxSafeInteger);
      expect(checkedAdd(maxSafeInteger, 0), maxSafeInteger);
      expect(checkedMultiply(maxSafeInteger, 1), maxSafeInteger);
    });

    test('separates unsafe arithmetic from active-budget failures', () {
      _expectFormatError(() => checkedAdd(maxSafeInteger, 1), FormatErrorCode.integerUnsafe);
      _expectFormatError(() => checkedMultiply(maxSafeInteger, 2), FormatErrorCode.integerUnsafe);
      _expectFormatError(() => checkedAdd(4, 5, 8), FormatErrorCode.budgetExceeded);
      _expectFormatError(() => checkedMultiply(3, 3, 8), FormatErrorCode.budgetExceeded);
      for (final value in [-1]) {
        _expectFormatError(() => checkedNonNegativeInteger(value), FormatErrorCode.integerUnsafe);
      }
    });

    test('aligns and calculates ranges without overflowing', () {
      expect(align8(0), 0);
      expect(align8(1), 8);
      expect(align8(8), 8);
      expect(align8(maxSafeInteger - 7), maxSafeInteger - 7);
      _expectFormatError(() => align8(maxSafeInteger), FormatErrorCode.integerUnsafe);
      expect(checkedRangeEnd(10, 5), 15);
      expect(rangeContains(10, 10, 10, 10), true);
      expect(rangeContains(10, 10, 9, 1), false);
      expect(rangeContains(10, 10, 20, 0), true);
      expect(rangeContains(10, 10, 20, 1), false);
    });

    test('converts uint64 values only after bigint safety and budget checks', () {
      expect(bigintToSafeNumber(BigInt.from(maxSafeInteger)), maxSafeInteger);
      _expectFormatError(
        () => bigintToSafeNumber(BigInt.from(maxSafeInteger) + BigInt.one),
        FormatErrorCode.integerUnsafe,
      );
      _expectFormatError(
        () => bigintToSafeNumber(BigInt.from(9), 8),
        FormatErrorCode.budgetExceeded,
      );
    });
  });

  group('bounded little-endian byte access', () {
    test('round-trips values through an unaligned Uint8List view', () {
      final storage = Uint8List(40);
      final view = Uint8List.sublistView(storage, 3, 35);

      writeUint16LE(view, 1, 0xabcd);
      writeUint32LE(view, 3, 0xfedcba98);
      writeUint64LE(view, 7, BigInt.parse('123456789abcde', radix: 16));

      expect(readUint16LE(view, 1), 0xabcd);
      expect(readUint32LE(view, 3), 0xfedcba98);
      expect(readUint64LEBigInt(view, 7), BigInt.parse('123456789abcde', radix: 16));
      expect(storage[2], 0);
      expect(storage[3], 0);
    });

    test('reads bigint before rejecting MAX_SAFE_INTEGER + 1', () {
      final bytes = Uint8List(8);
      writeUint64LE(bytes, 0, BigInt.from(maxSafeInteger) + BigInt.one);
      expect(readUint64LEBigInt(bytes, 0), BigInt.from(maxSafeInteger) + BigInt.one);
      _expectFormatError(() => readUint64LE(bytes, 0), FormatErrorCode.integerUnsafe);
    });

    test('prechecks every complete read and write range', () {
      for (var length = 0; length < 8; length += 1) {
        final bytes = Uint8List(length);
        _expectFormatError(
          () => readUint64LEBigInt(bytes, 0, FormatErrorCode.indexInvalid),
          FormatErrorCode.indexInvalid,
        );
        _expectFormatError(
          () => writeUint64LE(bytes, 0, BigInt.zero, FormatErrorCode.indexInvalid),
          FormatErrorCode.indexInvalid,
        );
      }
      _expectFormatError(
        () => requireByteRange(Uint8List(4), 3, 2, FormatErrorCode.layoutInvalid),
        FormatErrorCode.layoutInvalid,
      );
    });
  });

  group('budgets and stable errors', () {
    test('merges only lower safe overrides into an immutable result', () {
      final resolved = resolveFormatBudgets(
        const FormatOptions(budgets: {'maxManifestBytes': 512, 'maxEdges': 0}),
      );
      expect(resolved.maxManifestBytes, 512);
      expect(resolved.maxEdges, 0);
      expect(resolved.maxFileBytes, formatDefaultBudgets.maxFileBytes);
    });

    test('rejects raised, negative, and unknown overrides', () {
      _expectFormatError(
        () => resolveFormatBudgets(
          FormatOptions(budgets: {'maxFileBytes': formatDefaultBudgets.maxFileBytes + 1}),
        ),
        FormatErrorCode.inputInvalid,
      );
      _expectFormatError(
        () => resolveFormatBudgets(const FormatOptions(budgets: {'maxEdges': -1})),
        FormatErrorCode.inputInvalid,
      );
      _expectFormatError(
        () => resolveFormatBudgets(const FormatOptions(budgets: {'unknown': 1})),
        FormatErrorCode.inputInvalid,
      );
    });

    test('carries the stable FormatError properties', () {
      final error = FormatError(
        FormatErrorCode.headerInvalid,
        'bad header',
        const FormatErrorDetails(path: 'header.magic', offset: 3),
      );
      expect(error.name, 'FormatError');
      expect(error.code, FormatErrorCode.headerInvalid);
      expect(error.path, 'header.magic');
      expect(error.offset, 3);
    });
  });
}
