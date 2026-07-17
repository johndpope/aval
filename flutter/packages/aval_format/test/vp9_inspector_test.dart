/// Dart port of `packages/format/test/vp9-inspector.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/vp9/index.dart';
import 'package:test/test.dart';

final Uint8List key = Uint8List.fromList(
  [0x82, 0x49, 0x83, 0x42, 0x40, 0x03, 0xf0, 0x01, 0xf6, 0x08],
);

void main() {
  group('VP9 rendition inspection', () {
    test('derives a fully qualified codec and permits hidden frames', () {
      const marker = 0xc1;
      final hiddenAndShown =
          Uint8List.fromList([0x84, 0x86, marker, 1, 1, marker]);
      final inspection = inspectVp9Rendition(Vp9RenditionInspectionInput(
        width: 64,
        height: 32,
        frameRate: (numerator: 30, denominator: 1),
        averageBitrate: 100000,
        units: [
          Vp9UnitInput(
            id: 'idle',
            expectedDisplayedFrames: 2,
            packets: [
              Vp9PacketInput(bytes: key, key: true, timestamp: 0),
              Vp9PacketInput(bytes: hiddenAndShown, key: false, timestamp: 1),
            ],
          ),
        ],
      ));

      expect(inspection.codec, 'vp09.00.10.08.01.01.01.01.00');
      expect(inspection.width, 64);
      expect(inspection.height, 32);
      expect(inspection.bitDepth, 8);
      expect(inspection.units[0].displayedFrameCount, 2);
    });

    test('rejects a non-key unit start and authored display mismatch', () {
      Vp9RenditionInspectionInput base(List<Vp9UnitInput> units) =>
          Vp9RenditionInspectionInput(
            width: 64,
            height: 32,
            frameRate: (numerator: 30, denominator: 1),
            averageBitrate: 100000,
            units: units,
          );

      expect(
        () => inspectVp9Rendition(base([
          Vp9UnitInput(
            id: 'idle',
            expectedDisplayedFrames: 1,
            packets: [
              Vp9PacketInput(
                bytes: Uint8List.fromList([0x86]),
                key: false,
                timestamp: 0,
              ),
            ],
          ),
        ])),
        throwsA(predicate<Object>((error) =>
            error is FormatError &&
            RegExp('start with a key').hasMatch(error.message))),
      );

      expect(
        () => inspectVp9Rendition(base([
          Vp9UnitInput(
            id: 'idle',
            expectedDisplayedFrames: 2,
            packets: [
              Vp9PacketInput(bytes: key, key: true, timestamp: 0),
            ],
          ),
        ])),
        throwsA(predicate<Object>((error) =>
            error is FormatError &&
            RegExp('displayed frame count').hasMatch(error.message))),
      );
    });
  });
}
