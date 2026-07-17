/// Dart port of `packages/format/test/av1-inspector.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/av1/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

// Hex "00000002a7ff36be4404040410".
final Uint8List sequence = Uint8List.fromList([
  0x00, 0x00, 0x00, 0x02, 0xa7, 0xff, 0x36, 0xbe, 0x44, 0x04, 0x04, 0x04, 0x10,
]);

Uint8List obu(int type, Uint8List payload) {
  return Uint8List.fromList([
    type << 3 | 0x02,
    payload.length,
    ...payload,
  ]);
}

Uint8List packet(List<Uint8List> parts) {
  final length = parts.fold<int>(0, (total, part) => total + part.length);
  final output = Uint8List(length);
  var cursor = 0;
  for (final part in parts) {
    output.setRange(cursor, cursor + part.length, part);
    cursor += part.length;
  }
  return output;
}

void main() {
  group('AV1 rendition inspection', () {
    test(
        'derives a fully qualified codec and preserves frame display semantics',
        () {
      final key = packet([
        obu(2, Uint8List(0)),
        obu(1, sequence),
        obu(6, Uint8List.fromList([0x14])),
      ]);
      final hiddenAndShown = packet([
        obu(2, Uint8List(0)),
        obu(6, Uint8List.fromList([0x24])),
        obu(6, Uint8List.fromList([0x34])),
      ]);
      final inspection = inspectAv1Rendition(Av1RenditionInspectionInput(
        width: 64,
        height: 32,
        bitDepth: 8,
        units: [
          Av1UnitInput(
            id: 'idle',
            expectedDisplayedFrames: 2,
            chunks: [
              Av1ChunkInput(bytes: key, key: true, timestamp: 0),
              Av1ChunkInput(bytes: hiddenAndShown, key: false, timestamp: 1),
            ],
          ),
        ],
      ));

      expect(inspection.codec, 'av01.0.00M.08.0.110.01.01.01.0');
      expect(inspection.sequence.bitDepth, 8);
      expect(inspection.sequence.maxWidth, 64);
      expect(inspection.sequence.maxHeight, 32);
      expect(inspection.units[0].displayedFrameCount, 2);
    });

    test('rejects units without a shown key start and display mismatches', () {
      final key = packet([
        obu(2, Uint8List(0)),
        obu(1, sequence),
        obu(6, Uint8List.fromList([0x14])),
      ]);
      expect(
        () => inspectAv1Rendition(Av1RenditionInspectionInput(
          width: 64,
          height: 32,
          bitDepth: 8,
          units: [
            Av1UnitInput(
              id: 'idle',
              expectedDisplayedFrames: 2,
              chunks: [Av1ChunkInput(bytes: key, key: true, timestamp: 0)],
            ),
          ],
        )),
        throwsA(predicate<Object>((error) =>
            error is FormatError &&
            RegExp('displayed frame count').hasMatch(error.message))),
      );
    });
  });
}
