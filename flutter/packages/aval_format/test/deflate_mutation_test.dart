/// Dart port of `packages/format/test/deflate-mutation.test.ts`.
///
/// Uses `dart:io`'s `ZLibEncoder(raw: true)` test-only, exactly as
/// `deflate_test.dart` does, to generate the one real compressed vector this
/// fixed-seed mutation sweep repeatedly corrupts.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/png/deflate.dart';
import 'package:test/test.dart';

void main() {
  group('DEFLATE fixed-seed mutations', () {
    test('never escapes stable failure or the exact bounded output', () {
      final source = Uint8List.fromList(
        List<int>.generate(
          2048,
          (index) => (index * 17 + (index >> 3) * 41) & 0xff,
        ),
      );
      final raw = Uint8List.fromList(
        ZLibEncoder(raw: true, level: 9).convert(source),
      );
      var seed = 0xa341316c;
      for (var iteration = 0; iteration < 512; iteration += 1) {
        seed = (_imul(seed ^ (seed >> 16), 0x45d9f3b) + iteration) & 0xffffffff;
        final mutated = Uint8List.fromList(raw);
        final offset = seed % mutated.length;
        mutated[offset] = mutated[offset] ^ (1 << ((seed >> 11) & 7));
        try {
          final output = inflateDeflate(
            DeflateInflateInput(
              deflate: mutated,
              expectedOutputLength: source.length,
            ),
          );
          expect(output.length, equals(source.length));
        } catch (error) {
          expect(error, isA<FormatError>());
          expect(
            (error as FormatError).code,
            equals(FormatErrorCode.pngDeflateInvalid),
          );
          expect(error.message.length, lessThan(256));
        }
        mutated.fillRange(0, mutated.length, 0);
      }
    });
  });
}

/// 32-bit `Math.imul` equivalent (low 32 bits of the product are identical
/// whether the operands are treated as signed or unsigned).
int _imul(int a, int b) {
  return (a * b) & 0xffffffff;
}
