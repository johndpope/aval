/// Dart port of `packages/format/test/avc-decoder-surface.test.ts`.
library;

import 'package:aval_format/src/avc/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

const int _maxSafeInteger = 9007199254740991;

void main() {
  group('AVC decoder surface reserve', () {
    test('reserves two padded macroblocks beyond aligned coded geometry', () {
      expect(maximumAvcDecoderSurfaceDimension(32), 64);
      expect(maximumAvcDecoderSurfaceDimension(33), 80);
      expect(maximumAvcDecodedRgbaBytes(32, 32), 64 * 64 * 4);
    });

    test('accepts larger representable dimensions and rejects unsafe arithmetic', () {
      expect(() => maximumAvcDecoderSurfaceDimension(0), throwsA(anything));
      expect(maximumAvcDecoderSurfaceDimension(2049), 2096);
      expect(
        () => maximumAvcDecoderSurfaceDimension(_maxSafeInteger),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatError && error.message.contains('safe-integer'),
          ),
        ),
      );
    });
  });
}
