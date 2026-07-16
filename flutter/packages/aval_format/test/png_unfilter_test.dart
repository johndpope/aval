/// Dart port of `packages/format/test/png-unfilter.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/png/unfilter.dart';
import 'package:test/test.dart';

import 'png_test_fixture.dart';

void main() {
  group('PNG RGBA scanline reconstruction', () {
    test('reconstructs filters 0 through 4 independently and mixed', () {
      const width = 5;
      const height = 7;
      final rgba = patternedRgba(width, height);
      for (final filters in <List<int>>[
        [0],
        [1],
        [2],
        [3],
        [4],
        [0, 1, 2, 3, 4],
      ]) {
        final filtered = filterRgba(rgba, width, height, filters);
        expect(_unfilter(filtered, width, height), equals(rgba));
      }
    });

    test('uses modulo-256 Sub/Average arithmetic and PNG Paeth ties', () {
      final rgba = Uint8List.fromList(const [
        250, 1, 128, 255, 2, 255, 0, 1, //
        1, 250, 255, 0, 255, 2, 128, 254,
      ]);
      for (final filter in [1, 3, 4]) {
        final filtered = filterRgba(rgba, 2, 2, [filter]);
        expect(_unfilter(filtered, 2, 2), equals(rgba));
      }

      final tie = Uint8List(18);
      tie.setRange(0, 9, const [0, 2, 0, 0, 0, 3, 0, 0, 0]);
      tie[9] = 4;
      tie[10] = 254; // up=2 reconstructs current-row left to zero.
      tie[14] = 10; // left=0 and upper-left=2 tie; PNG selects left.
      expect(_unfilter(tie, 2, 2)[12], equals(10));
    });

    test('rejects wrong lengths, dimensions, and filter bytes with scanline code', () {
      _expectScanlineError(() => _unfilter(Uint8List(17), 2, 2));
      _expectScanlineError(() => _unfilter(Uint8List(18), 0, 2));
      _expectScanlineError(() {
        final filtered = Uint8List(18);
        filtered[0] = 5;
        return _unfilter(filtered, 2, 2);
      });
    });
  });
}

Uint8List _unfilter(Uint8List filtered, int width, int height) {
  return unfilterPngRgba(
    PngUnfilterInput(
      filtered: filtered,
      layout: derivePngRgbaLayout(width, height),
    ),
  );
}

void _expectScanlineError(Object? Function() action) {
  try {
    action();
  } catch (error) {
    expect(error, isA<FormatError>());
    expect(
      (error as FormatError).code,
      equals(FormatErrorCode.pngScanlineInvalid),
    );
    return;
  }
  fail('expected PNG scanline failure');
}
