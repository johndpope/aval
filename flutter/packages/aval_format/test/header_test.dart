// Dart port of packages/format/test/header.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/checked_integer.dart'
    show writeUint32LE, writeUint64LE, maxSafeInteger;
import 'package:aval_format/src/constants.dart';
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/header.dart';
import 'package:aval_format/src/model.dart' show FormatHeader, FormatOptions;
import 'package:test/test.dart';

final FormatHeader kHeader = FormatHeader(
  declaredFileLength: 136,
  manifestLength: 8,
  indexOffset: 72,
  indexLength: 64,
);

const String goldenHex = '41564c460d0a1a0a'
    '01000000'
    '40000000'
    '00000000'
    '00000000'
    '8800000000000000'
    '4000000000000000'
    '0800000000000000'
    '4800000000000000'
    '4000000000000000';

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

FormatError _expectFormatError(dynamic Function() operation, FormatErrorCode code) {
  try {
    operation();
  } on FormatError catch (error) {
    expect(error.code, code);
    return error;
  }
  fail('expected operation to throw');
}

void main() {
  group('version-1.0 header codec', () {
    test('emits the exact canonical 64-byte little-endian header', () {
      final bytes = encodeHeader(kHeader);
      expect(bytes.length, 64);
      expect(hex(bytes), goldenHex);
      expect(bytes.sublist(0, 8), formatMagic);
    });

    test('parses the exact fields', () {
      final parsed = parseHeader(encodeHeader(kHeader));
      expect(parsed.major, kHeader.major);
      expect(parsed.minor, kHeader.minor);
      expect(parsed.headerLength, kHeader.headerLength);
      expect(parsed.declaredFileLength, kHeader.declaredFileLength);
      expect(parsed.manifestOffset, kHeader.manifestOffset);
      expect(parsed.manifestLength, kHeader.manifestLength);
      expect(parsed.indexOffset, kHeader.indexOffset);
      expect(parsed.indexLength, kHeader.indexLength);
    });

    test('supports an unaligned Uint8List view without reading adjacent bytes', () {
      final storage = Uint8List(70)..fillRange(0, 70, 0xa5);
      final view = Uint8List.sublistView(storage, 3, 67);
      view.setRange(0, 64, encodeHeader(kHeader));

      final parsed = parseHeader(view);
      expect(parsed.declaredFileLength, kHeader.declaredFileLength);
      expect(storage.sublist(0, 3), [0xa5, 0xa5, 0xa5]);
      expect(storage.sublist(67), [0xa5, 0xa5, 0xa5]);
    });

    test('rejects truncation at every byte boundary with one stable error', () {
      final bytes = encodeHeader(kHeader);
      for (var length = 0; length < formatHeaderLength; length += 1) {
        _expectFormatError(
          () => parseHeader(Uint8List.sublistView(bytes, 0, length)),
          FormatErrorCode.headerInvalid,
        );
      }
    });

    test('rejects every noncanonical fixed header field', () {
      final mutations = <(int, int, FormatErrorCode)>[
        (0, 0, FormatErrorCode.headerInvalid),
        (8, 2, FormatErrorCode.versionUnsupported),
        (10, 2, FormatErrorCode.versionUnsupported),
        (12, 63, FormatErrorCode.headerInvalid),
        (16, 1, FormatErrorCode.featureUnsupported),
        (20, 1, FormatErrorCode.headerInvalid),
      ];
      for (final (offset, value, code) in mutations) {
        final bytes = encodeHeader(kHeader);
        bytes[offset] = value;
        _expectFormatError(() => parseHeader(bytes), code);
      }
    });

    test('rejects unsafe uint64 fields but accepts files above the former ceiling', () {
      final unsafe = encodeHeader(kHeader);
      writeUint64LE(unsafe, 24, BigInt.from(maxSafeInteger) + BigInt.one);
      _expectFormatError(() => parseHeader(unsafe), FormatErrorCode.integerUnsafe);

      final large = FormatHeader(
        declaredFileLength: 40 * 1024 * 1024,
        manifestLength: kHeader.manifestLength,
        indexOffset: kHeader.indexOffset,
        indexLength: kHeader.indexLength,
      );
      expect(parseHeader(encodeHeader(large)).declaredFileLength, large.declaredFileLength);
      _expectFormatError(
        () => parseHeader(
          encodeHeader(large),
          const FormatOptions(budgets: {'maxFileBytes': 32 * 1024 * 1024}),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('enforces canonical offsets, index shape, count, and containment', () {
      final wrongManifestOffset = encodeHeader(kHeader);
      writeUint64LE(wrongManifestOffset, 32, 65);
      _expectFormatError(() => parseHeader(wrongManifestOffset), FormatErrorCode.headerInvalid);

      final wrongIndexOffset = encodeHeader(kHeader);
      writeUint64LE(wrongIndexOffset, 48, 80);
      _expectFormatError(() => parseHeader(wrongIndexOffset), FormatErrorCode.headerInvalid);

      final partialRecord = encodeHeader(kHeader);
      writeUint64LE(partialRecord, 56, 17);
      _expectFormatError(() => parseHeader(partialRecord), FormatErrorCode.headerInvalid);

      final outsideFile = encodeHeader(kHeader);
      writeUint64LE(outsideFile, 24, 135);
      _expectFormatError(() => parseHeader(outsideFile), FormatErrorCode.headerInvalid);

      final formerRecordLimit = FormatHeader(
        declaredFileLength: 200000,
        manifestLength: kHeader.manifestLength,
        indexOffset: kHeader.indexOffset,
        indexLength: chunkIndexHeaderLength + chunkIndexRecordLength * 3601,
      );
      expect(parseHeader(encodeHeader(formerRecordLimit)).indexLength, formerRecordLimit.indexLength);

      final outsideUint32 = FormatHeader(
        declaredFileLength: 72 + chunkIndexHeaderLength + chunkIndexRecordLength * 0x100000000,
        manifestLength: kHeader.manifestLength,
        indexOffset: kHeader.indexOffset,
        indexLength: chunkIndexHeaderLength + chunkIndexRecordLength * 0x100000000,
      );
      _expectFormatError(() => encodeHeader(outsideUint32), FormatErrorCode.budgetExceeded);
    });

    test('honors lower-only active budgets', () {
      _expectFormatError(
        () => parseHeader(encodeHeader(kHeader), const FormatOptions(budgets: {'maxFileBytes': 135})),
        FormatErrorCode.budgetExceeded,
      );
      _expectFormatError(
        () => parseHeader(encodeHeader(kHeader), const FormatOptions(budgets: {'maxManifestBytes': 7})),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('does not mistake reserved bytes for part of a numeric field', () {
      final bytes = encodeHeader(kHeader);
      writeUint32LE(bytes, 20, 0x01020304);
      _expectFormatError(() => parseHeader(bytes), FormatErrorCode.headerInvalid);
    });
  });
}
