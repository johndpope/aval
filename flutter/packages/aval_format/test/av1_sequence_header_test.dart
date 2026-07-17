/// Dart port of `packages/format/test/av1-sequence-header.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/av1/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

// Hex "00000002a7ff36be4404040410".
final Uint8List libaom64x32_8bit = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x02, 0xa7, 0xff, 0x36, 0xbe, 0x44, 0x04, 0x04, 0x04, 0x10,
]);

void main() {
  group('AV1 sequence-header parsing', () {
    test('parses the libaom Main-profile BT.709 sequence header', () {
      final sequence = parseAv1SequenceHeader(libaom64x32_8bit);
      expect(sequence.profile, 0);
      expect(sequence.level, 0);
      expect(sequence.tier, 'M');
      expect(sequence.bitDepth, 8);
      expect(sequence.maxWidth, 64);
      expect(sequence.maxHeight, 32);
      expect(sequence.monochrome, isFalse);
      expect(sequence.subsamplingX, 1);
      expect(sequence.subsamplingY, 1);
      expect(sequence.colorPrimaries, 1);
      expect(sequence.transferCharacteristics, 1);
      expect(sequence.matrixCoefficients, 1);
      expect(sequence.fullRange, isFalse);
    });

    test('rejects truncation and color-description mutation', () {
      expect(
        () => parseAv1SequenceHeader(libaom64x32_8bit.sublist(0, 4)),
        throwsA(predicate<Object>((error) =>
            error is FormatError &&
            RegExp('truncated').hasMatch(error.message))),
      );
      final changed = Uint8List.fromList(libaom64x32_8bit);
      changed[10] = changed[10] ^ 0x80;
      expect(() => parseAv1SequenceHeader(changed), throwsA(isA<FormatError>()));
    });
  });
}
