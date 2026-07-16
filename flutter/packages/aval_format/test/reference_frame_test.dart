// Dart port of packages/format/test/reference-frame.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/checked_integer.dart' show writeUint16LE, writeUint32LE;
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show FormatOptions;
import 'package:aval_format/src/reference_frame.dart';
import 'package:test/test.dart';

final Uint8List rgba = Uint8List.fromList([1, 2, 3, 4]);
const String goldenHex = '41565246000118000000000001000100040302010400000001020304';

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

FormatError _expectFormatError(
  dynamic Function() operation, [
  FormatErrorCode code = FormatErrorCode.referenceFrameInvalid,
]) {
  try {
    operation();
  } on FormatError catch (error) {
    expect(error.code, code);
    return error;
  }
  fail('expected operation to throw');
}

void main() {
  group('reference-rgba-v0 sample profile', () {
    test('encodes the exact 24-byte AVRF header and row-major RGBA payload', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0x01020304, rgba: rgba),
      );
      expect(sample.length, 28);
      expect(_hex(sample), goldenHex);
    });

    test('parses header metadata without requiring or retaining payload bytes', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 7, rgba: rgba),
      );
      final header = parseReferenceFrameHeader(Uint8List.sublistView(sample, 0, 24));
      expect(header.width, 1);
      expect(header.height, 1);
      expect(header.frameIndex, 7);
      expect(header.rgbaLength, 4);
      sample.fillRange(0, sample.length, 0);
      expect(header.frameIndex, 7);
    });

    test('validates an exact sample and returns only a numeric RGBA range', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 3, rgba: rgba),
      );
      final descriptor = validateReferenceFrame(ReferenceFrameValidationInput(
        sample: sample,
        expectedWidth: 1,
        expectedHeight: 1,
        expectedFrameIndex: 3,
      ));
      expect(descriptor.width, 1);
      expect(descriptor.height, 1);
      expect(descriptor.frameIndex, 3);
      expect(descriptor.rgbaLength, 4);
      expect(descriptor.rgbaRange.offset, 24);
      expect(descriptor.rgbaRange.length, 4);
    });

    test('supports reference samples above the former 2 MiB ceiling', () {
      const width = 1024;
      const height = 513;
      final bigRgba = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 0x7f);
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: width, height: height, frameIndex: 0, rgba: bigRgba),
      );

      expect(sample.length, greaterThan(2 * 1024 * 1024));
      expect(
        validateReferenceFrame(ReferenceFrameValidationInput(
          sample: sample,
          expectedWidth: width,
          expectedHeight: height,
          expectedFrameIndex: 0,
        )).rgbaLength,
        bigRgba.length,
      );
      _expectFormatError(
        () => validateReferenceFrame(ReferenceFrameValidationInput(
          sample: sample,
          expectedWidth: width,
          expectedHeight: height,
          expectedFrameIndex: 0,
          options: const FormatOptions(budgets: {'maxSampleBytes': 2 * 1024 * 1024}),
        )),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('supports an unaligned sample view', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      final storage = Uint8List(sample.length + 5)..fillRange(0, sample.length + 5, 0xa5);
      final view = Uint8List.sublistView(storage, 2, 2 + sample.length);
      view.setRange(0, sample.length, sample);
      final descriptor = validateReferenceFrame(ReferenceFrameValidationInput(
        sample: view,
        expectedWidth: 1,
        expectedHeight: 1,
        expectedFrameIndex: 0,
      ));
      expect(descriptor.rgbaRange.offset, 24);
      expect(descriptor.rgbaRange.length, 4);
      expect(storage.sublist(0, 2), [0xa5, 0xa5]);
      expect(storage.sublist(2 + sample.length), [0xa5, 0xa5, 0xa5]);
    });

    test('rejects truncation throughout the fixed header', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      for (var length = 0; length < 24; length += 1) {
        _expectFormatError(() => parseReferenceFrameHeader(Uint8List.sublistView(sample, 0, length)));
      }
    });

    test('rejects every fixed-header field mutation', () {
      final original = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      final mutations = <void Function(Uint8List)>[
        (bytes) => bytes[0] = 0,
        (bytes) => bytes[4] = 1,
        (bytes) => bytes[5] = 2,
        (bytes) => writeUint16LE(bytes, 6, 23),
        (bytes) => writeUint32LE(bytes, 8, 1),
        (bytes) => writeUint16LE(bytes, 12, 0),
        (bytes) => writeUint16LE(bytes, 14, 0),
        (bytes) => writeUint32LE(bytes, 20, 5),
      ];
      for (final mutate in mutations) {
        final sample = Uint8List.fromList(original);
        mutate(sample);
        _expectFormatError(() => parseReferenceFrameHeader(sample));
      }
    });

    test('checks the dimension product before accepting the declared RGBA length', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      writeUint16LE(sample, 12, 2);
      _expectFormatError(() => parseReferenceFrameHeader(sample));

      _expectFormatError(
        () => parseReferenceFrameHeader(
          encodeReferenceFrame(ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba)),
          const FormatOptions(budgets: {'maxSampleBytes': 27}),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('cross-checks rendition dimensions and index-record frame identity', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 4, rgba: rgba),
      );
      _expectFormatError(() => validateReferenceFrame(ReferenceFrameValidationInput(
            sample: sample,
            expectedWidth: 2,
            expectedHeight: 1,
            expectedFrameIndex: 4,
          )));
      _expectFormatError(() => validateReferenceFrame(ReferenceFrameValidationInput(
            sample: sample,
            expectedWidth: 1,
            expectedHeight: 1,
            expectedFrameIndex: 5,
          )));
    });

    test('rejects missing final RGBA bytes and any trailing bytes', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      _expectFormatError(() => validateReferenceFrame(ReferenceFrameValidationInput(
            sample: Uint8List.sublistView(sample, 0, sample.length - 1),
            expectedWidth: 1,
            expectedHeight: 1,
            expectedFrameIndex: 0,
          )));
      final trailing = Uint8List(sample.length + 1)..setRange(0, sample.length, sample);
      _expectFormatError(() => validateReferenceFrame(ReferenceFrameValidationInput(
            sample: trailing,
            expectedWidth: 1,
            expectedHeight: 1,
            expectedFrameIndex: 0,
          )));
    });

    test('treats every possible final alpha byte as data', () {
      final sample = encodeReferenceFrame(
        ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: rgba),
      );
      expect(sample[27], 4);
      sample[27] = 0xff;
      expect(
        validateReferenceFrame(ReferenceFrameValidationInput(
          sample: sample,
          expectedWidth: 1,
          expectedHeight: 1,
          expectedFrameIndex: 0,
        )).rgbaLength,
        4,
      );
    });

    test('rejects malformed encoder input', () {
      _expectFormatError(
        () => encodeReferenceFrame(ReferenceFrameInput(width: 1, height: 1, frameIndex: 0, rgba: Uint8List(3))),
      );
    });
  });
}
