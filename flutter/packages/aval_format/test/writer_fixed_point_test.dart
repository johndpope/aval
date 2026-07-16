// Dart port of packages/format/test/writer-fixed-point.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/writer_fixed_point.dart';
import 'package:test/test.dart';

void main() {
  group('writer fixed-point runner', () {
    test('returns the first byte-stable value and its associated result', () {
      final result = resolveByteStableFixedPoint<int, String>(
        0,
        Uint8List.fromList([0]),
        4,
        (value, bytes) => ByteFixedPointStep(
          value: value + 1,
          bytes: Uint8List.fromList([(value + 1).clamp(0, 1)]),
          result: 'step-${value + 1}',
        ),
      );

      expect(result.value, 2);
      expect(result.bytes, [1]);
      expect(result.result, 'step-2');
      expect(result.iterations, 2);
    });

    test('deterministically forces the planned non-convergence branch', () {
      expect(
        () => resolveByteStableFixedPoint<bool, Null>(
          false,
          Uint8List.fromList([0]),
          4,
          (value, bytes) => ByteFixedPointStep(
            value: !value,
            bytes: Uint8List.fromList([value ? 0 : 1]),
            result: null,
          ),
        ),
        throwsA(
          predicate((e) => e is FormatError && e.code == FormatErrorCode.writerNonconvergent),
        ),
      );
    });
  });
}
