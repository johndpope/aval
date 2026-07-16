/// Dart port of `packages/format/test/png-profile-mutation.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/png/profile.dart';
import 'package:test/test.dart';

import 'png_test_fixture.dart';

void main() {
  group('strict PNG fixed-seed mutations', () {
    test('returns a detached plan or one stable bounded rejection for every byte mutation', () {
      final source = makeTestPng(
        TestPngInput(width: 4, height: 3, compression: 'dynamic'),
      );
      var seed = 0x6d2b79f5;
      for (var iteration = 0; iteration < 512; iteration += 1) {
        seed = (_imul(seed ^ (seed >> 15), 1 | seed) + 0x9e3779b9) & 0xffffffff;
        final bytes = Uint8List.fromList(source);
        final offset = seed % bytes.length;
        bytes[offset] = bytes[offset] ^ (1 << ((seed >> 8) & 7));
        try {
          final plan = validatePngProfile(
            PngProfileValidationInput(
              png: bytes,
              expectedWidth: 4,
              expectedHeight: 3,
            ),
          );
          bytes.fillRange(0, bytes.length, 0);
          expect(plan.copyZlibBytes().any((byte) => byte != 0), isTrue);
        } catch (error) {
          expect(error, isA<FormatError>());
          expect(
            (error as FormatError).code,
            anyOf(
              FormatErrorCode.pngEnvelopeInvalid,
              FormatErrorCode.budgetExceeded,
            ),
          );
          expect(error.message.length, lessThan(256));
        }
      }
    });
  });
}

/// 32-bit `Math.imul` equivalent (low 32 bits of the product are identical
/// whether the operands are treated as signed or unsigned).
int _imul(int a, int b) {
  return (a * b) & 0xffffffff;
}
