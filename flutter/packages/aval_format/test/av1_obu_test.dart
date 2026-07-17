/// Dart port of `packages/format/test/av1-obu.test.ts`.
library;

import 'dart:typed_data';

import 'package:aval_format/src/av1/index.dart';
import 'package:aval_format/src/errors.dart';
import 'package:test/test.dart';

void main() {
  group('AV1 low-overhead OBU parsing', () {
    test(
        'parses temporal delimiter, sequence, and frame OBUs into owned payloads',
        () {
      final bytes = Uint8List.fromList(
          [0x12, 0x00, 0x0a, 0x02, 0xaa, 0xbb, 0x32, 0x01, 0x14]);
      final parsed = parseAv1LowOverheadObus(bytes);
      expect(parsed, equals([
        Av1Obu(type: 2, temporalId: 0, spatialId: 0, payload: Uint8List(0)),
        Av1Obu(
            type: 1,
            temporalId: 0,
            spatialId: 0,
            payload: Uint8List.fromList([0xaa, 0xbb])),
        Av1Obu(
            type: 6,
            temporalId: 0,
            spatialId: 0,
            payload: Uint8List.fromList([0x14])),
      ]));
      bytes.fillRange(0, bytes.length, 0);
      expect(parsed[1].payload, equals(Uint8List.fromList([0xaa, 0xbb])));
    });

    test('requires canonical bounded LEB128 and valid OBU headers', () {
      expect(readAv1Leb128(Uint8List.fromList([0x81, 0x01]), 0),
          equals(const Av1Leb128(value: 129, length: 2)));
      for (final bytes in [
        Uint8List.fromList([0x80, 0x00]),
        Uint8List.fromList([0x80]),
        Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]),
      ]) {
        expect(() => readAv1Leb128(bytes, 0), throwsA(isA<FormatError>()));
      }
      for (final bytes in [
        Uint8List.fromList([0x92, 0x00]),
        Uint8List.fromList([0x10]),
        Uint8List.fromList([0x42, 0x00]),
        Uint8List.fromList([0x12, 0x01, 0x00]),
        Uint8List.fromList([0x32, 0x02, 0x14]),
      ]) {
        expect(
            () => parseAv1LowOverheadObus(bytes), throwsA(isA<FormatError>()));
      }
    });
  });
}
