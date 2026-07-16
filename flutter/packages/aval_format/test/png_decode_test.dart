/// Dart port of `packages/format/test/png-decode.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/png/decode.dart';
import 'package:aval_format/src/png/profile.dart';
import 'package:test/test.dart';

import 'png_test_fixture.dart';

void main() {
  group('pure restricted PNG decode', () {
    for (final compression in const ['stored', 'fixed', 'dynamic']) {
      test('decodes $compression DEFLATE into caller-owned RGBA', () {
        const width = 7;
        const height = 6;
        final rgba = patternedRgba(width, height);
        final plan = validatePngProfile(
          PngProfileValidationInput(
            png: makeTestPng(
              TestPngInput(
                width: width,
                height: height,
                rgba: rgba,
                filters: const [0, 1, 2, 3, 4],
                compression: compression,
              ),
            ),
            expectedWidth: width,
            expectedHeight: height,
          ),
        );
        final decoded = decodePngRgba(plan);
        expect(decoded.width, equals(width));
        expect(decoded.height, equals(height));
        expect(decoded.rgba, equals(rgba));
        decoded.rgba.fillRange(0, decoded.rgba.length, 0);
        expect(decodePngRgba(plan).rgba, equals(rgba));
      });
    }

    test('validates independently inflated bytes for the later native adapter', () {
      const width = 3;
      const height = 3;
      final rgba = patternedRgba(width, height);
      final filtered = filterRgba(rgba, width, height, const [4, 3, 2]);
      final plan = validatePngProfile(
        PngProfileValidationInput(
          png: makeTestPng(
            TestPngInput(
              width: width,
              height: height,
              rgba: rgba,
              filters: const [4, 3, 2],
            ),
          ),
          expectedWidth: width,
          expectedHeight: height,
        ),
      );
      expect(
        decodePngRgbaFromInflated(plan, filtered).rgba,
        equals(rgba),
      );

      final corrupt = Uint8List.fromList(filtered);
      corrupt[1] = corrupt[1] ^ 1;
      _expectDecodeError(() => decodePngRgbaFromInflated(plan, corrupt));
      _expectDecodeError(
        () => decodePngRgbaFromInflated(
          plan,
          Uint8List.sublistView(filtered, 1),
        ),
      );
    });

    test('rejects short/long inflate, Adler mismatch, and invalid scanline filters', () {
      for (final filteredLength in [17, 19]) {
        final plan = validatePngProfile(
          PngProfileValidationInput(
            png: makeTestPng(
              TestPngInput(
                width: 2,
                height: 2,
                zlib: storedZlib(Uint8List(filteredLength)),
              ),
            ),
            expectedWidth: 2,
            expectedHeight: 2,
          ),
        );
        _expectDecodeError(() => decodePngRgba(plan));
      }

      final wrongAdler = storedZlib(Uint8List(18));
      wrongAdler[wrongAdler.length - 1] = wrongAdler[wrongAdler.length - 1] ^ 1;
      final adlerPlan = validatePngProfile(
        PngProfileValidationInput(
          png: makeTestPng(
            TestPngInput(width: 2, height: 2, zlib: wrongAdler),
          ),
          expectedWidth: 2,
          expectedHeight: 2,
        ),
      );
      _expectDecodeError(() => decodePngRgba(adlerPlan));

      final invalidFilter = Uint8List(18);
      invalidFilter[0] = 5;
      final filterPlan = validatePngProfile(
        PngProfileValidationInput(
          png: makeTestPng(
            TestPngInput(
              width: 2,
              height: 2,
              zlib: storedZlib(invalidFilter),
            ),
          ),
          expectedWidth: 2,
          expectedHeight: 2,
        ),
      );
      _expectDecodeError(() => decodePngRgba(filterPlan));
    });

    test('decodes exact authored geometry and payloads above the former limits', () {
      const width = 1024;
      const height = 513;
      final rgba = patternedRgba(width, height);
      final plan = validatePngProfile(
        PngProfileValidationInput(
          png: makeTestPng(
            TestPngInput(
              width: width,
              height: height,
              rgba: rgba,
              compression: 'stored',
            ),
          ),
          expectedWidth: width,
          expectedHeight: height,
        ),
      );
      expect(plan.byteRange.length, greaterThan(2 * 1024 * 1024));
      expect(decodePngRgba(plan).rgba, equals(rgba));
    });
  });
}

void _expectDecodeError(Object? Function() action) {
  try {
    action();
  } catch (error) {
    expect(error, isA<FormatError>());
    expect(
      (error as FormatError).code,
      anyOf(
        FormatErrorCode.pngDeflateInvalid,
        FormatErrorCode.pngScanlineInvalid,
      ),
    );
    return;
  }
  fail('expected PNG decode failure');
}
