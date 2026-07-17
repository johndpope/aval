/// Dart port of `packages/format/test/vp9-frame-header.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/vp9/index.dart';
import 'package:test/test.dart';

final Uint8List key64x32Bt709 = Uint8List.fromList(
  [0x82, 0x49, 0x83, 0x42, 0x40, 0x03, 0xf0, 0x01, 0xf6, 0x08],
);

void main() {
  group('VP9 uncompressed frame headers', () {
    test('parses a limited-range BT.709 profile-0 key frame', () {
      expect(
        parseVp9FrameHeader(key64x32Bt709),
        equals(const Vp9FrameHeader(
          profile: 0,
          key: true,
          showFrame: true,
          showExistingFrame: false,
          displayedFrameCount: 1,
          errorResilient: false,
          width: 64,
          height: 32,
          renderWidth: 64,
          renderHeight: 32,
          color: Vp9ColorConfig(
            bitDepth: 8,
            chromaSubsampling: 1,
            colorPrimaries: 1,
            transferCharacteristics: 1,
            matrixCoefficients: 1,
            fullRange: false,
          ),
        )),
      );
    });

    test('retains hidden inter and show-existing semantics', () {
      final hidden = parseVp9FrameHeader(Uint8List.fromList([0x84]));
      expect(hidden.key, isFalse);
      expect(hidden.showFrame, isFalse);
      expect(hidden.showExistingFrame, isFalse);
      expect(hidden.displayedFrameCount, 0);

      final showExisting = parseVp9FrameHeader(Uint8List.fromList([0x88]));
      expect(showExisting.key, isFalse);
      expect(showExisting.showFrame, isTrue);
      expect(showExisting.showExistingFrame, isTrue);
      expect(showExisting.displayedFrameCount, 1);
    });

    test('rejects truncation, profiles other than zero, and wrong color', () {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([0x82, 0x49]),
        Uint8List.fromList([0x92]),
        Uint8List.fromList(
            [0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x01, 0xf6]),
      ]) {
        expect(() => parseVp9FrameHeader(bytes), throwsA(isA<FormatError>()));
      }
    });
  });
}
