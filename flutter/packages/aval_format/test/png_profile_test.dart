/// Dart port of `packages/format/test/png-profile.test.ts`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show FormatOptions;
import 'package:aval_format/src/png/crc32.dart';
import 'package:aval_format/src/png/profile.dart';
import 'package:test/test.dart';

import 'png_test_fixture.dart';

final Uint8List _signature = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
]);

void main() {
  group('strict restricted PNG profile', () {
    for (final compression in const ['stored', 'fixed', 'dynamic']) {
      test('accepts $compression zlib and returns one immutable owned decode plan', () {
        final source = makeTestPng(
          TestPngInput(
            width: 3,
            height: 2,
            compression: compression,
            idatSplits: const [1, 2, 0],
          ),
        );
        final original = Uint8List.fromList(source);
        final plan = validatePngProfile(
          PngProfileValidationInput(
            png: source,
            expectedWidth: 3,
            expectedHeight: 2,
          ),
        );

        expect(plan.width, equals(3));
        expect(plan.height, equals(2));
        expect(plan.byteRange.offset, equals(0));
        expect(plan.byteRange.length, equals(source.length));
        expect(plan.expectedFilteredBytes, equals(26));
        expect(plan.expectedRgbaBytes, equals(24));
        expect(plan.deflateRange.offset, equals(2));
        expect(plan.deflateRange.length, equals(plan.zlibByteLength - 6));

        final firstCopy = plan.copyZlibBytes();
        source.fillRange(0, source.length, 0);
        firstCopy.fillRange(0, firstCopy.length, 0);
        expect(plan.copyZlibBytes(), isNot(equals(firstCopy)));
        expect(original.any((byte) => byte != 0), isTrue);
      });
    }

    test('accepts the optional canonical sRGB only immediately after IHDR', () {
      expect(
        () => _validate(makeTestPng(TestPngInput(width: 2, height: 2))),
        returnsNormally,
      );
      expect(
        () => _validate(
          makeTestPng(
            TestPngInput(width: 2, height: 2, includeSrgb: false),
          ),
        ),
        returnsNormally,
      );

      final parts = _canonicalParts();
      for (final png in [
        concatenate([
          _signature,
          parts.ihdr,
          parts.srgb,
          parts.srgb,
          parts.idat,
          parts.iend,
        ]),
        concatenate([
          _signature,
          parts.ihdr,
          parts.idat,
          parts.srgb,
          parts.iend,
        ]),
        concatenate([
          _signature,
          parts.ihdr,
          chunk('sRGB', Uint8List.fromList(const [1])),
          parts.idat,
          parts.iend,
        ]),
      ]) {
        _expectPngError(() => _validate(png));
      }
    });

    test('rejects every whole-file truncation and trailing byte', () {
      final png = makeTestPng(TestPngInput(width: 2, height: 2));
      for (var length = 0; length < png.length; length += 1) {
        _expectPngError(() => _validate(Uint8List.sublistView(png, 0, length)));
      }
      final trailing = Uint8List(png.length + 1);
      trailing.setRange(0, png.length, png);
      _expectPngError(() => _validate(trailing));
    });

    test('rejects CRC, chunk length/count/order/type, and terminal-shape violations', () {
      final badCrc = makeTestPng(TestPngInput(width: 2, height: 2));
      badCrc[29] = badCrc[29] ^ 1;
      _expectPngError(() => _validate(badCrc));

      final crcParts = _canonicalParts();
      for (final key in const ['ihdr', 'srgb', 'idat', 'iend']) {
        final corrupted = _CanonicalParts(
          ihdr: Uint8List.fromList(crcParts.ihdr),
          srgb: Uint8List.fromList(crcParts.srgb),
          idat: Uint8List.fromList(crcParts.idat),
          iend: Uint8List.fromList(crcParts.iend),
          zlib: crcParts.zlib,
        );
        final target = corrupted.byKey(key);
        target[target.length - 1] = target[target.length - 1] ^ 1;
        _expectPngError(
          () => _validate(
            concatenate([
              _signature,
              corrupted.ihdr,
              corrupted.srgb,
              corrupted.idat,
              corrupted.iend,
            ]),
          ),
        );
      }

      final hugeLength = makeTestPng(TestPngInput(width: 2, height: 2));
      writeUint32Be(hugeLength, 8, 0xffffffff);
      _expectPngError(() => _validate(hugeLength));

      final parts = _canonicalParts();
      for (final png in [
        concatenate([_signature, parts.idat, parts.ihdr, parts.iend]),
        concatenate([
          _signature,
          parts.ihdr,
          parts.idat,
          chunk('tEXt', Uint8List(0)),
          parts.iend,
        ]),
        concatenate([
          _signature,
          parts.ihdr,
          parts.idat,
          chunk('IEND', Uint8List.fromList(const [0])),
        ]),
        concatenate([_signature, parts.ihdr, parts.iend]),
        concatenate([
          _signature,
          parts.ihdr,
          parts.idat,
          parts.iend,
          parts.iend,
        ]),
      ]) {
        _expectPngError(() => _validate(png));
      }

      final tooManyIdat = List<Uint8List>.generate(
        255,
        (index) => chunk('IDAT', index == 0 ? parts.zlib : Uint8List(0)),
      );
      final exactIdat = tooManyIdat.sublist(0, 254);
      expect(
        () => _validate(
          concatenate([_signature, parts.ihdr, ...exactIdat, parts.iend]),
        ),
        returnsNormally,
      );
      _expectPngError(
        () => _validate(
          concatenate([_signature, parts.ihdr, ...tooManyIdat, parts.iend]),
        ),
      );
    });

    test('rejects IHDR fields, descriptor mismatch, and noncanonical sRGB', () {
      for (final offset in const [16, 20, 24, 25, 26, 27, 28]) {
        final png = makeTestPng(TestPngInput(width: 2, height: 2));
        if (offset == 16 || offset == 20) {
          writeUint32Be(png, offset, 0);
        } else {
          png[offset] = png[offset] ^ 1;
        }
        _rewriteChunkCrc(png, 8);
        _expectPngError(() => _validate(png));
      }
      _expectPngError(
        () => validatePngProfile(
          PngProfileValidationInput(
            png: makeTestPng(TestPngInput(width: 2, height: 2)),
            expectedWidth: 3,
            expectedHeight: 2,
          ),
        ),
      );
    });

    test('rejects unrepresentable IHDR products with checked arithmetic', () {
      final png = makeTestPng(TestPngInput(width: 1, height: 1));
      writeUint32Be(png, 16, 0xffffffff);
      writeUint32Be(png, 20, 0xffffffff);
      _rewriteChunkCrc(png, 8);

      _expectPngError(
        () => validatePngProfile(
          PngProfileValidationInput(
            png: png,
            expectedWidth: 0xffffffff,
            expectedHeight: 0xffffffff,
          ),
        ),
        FormatErrorCode.integerUnsafe,
      );
    });

    test('rejects invalid zlib method/window/check/dictionary and a missing trailer', () {
      final filtered = Uint8List(18);
      final validZlib = storedZlib(filtered);
      final mutations = <void Function(Uint8List)>[
        (zlib) => zlib[0] = 0x79,
        (zlib) => zlib[0] = 0x88,
        (zlib) => zlib[1] = zlib[1] ^ 1,
        (zlib) {
          zlib[1] = zlib[1] | 0x20;
          zlib[1] = (zlib[1] + (31 - ((zlib[0] * 256 + zlib[1]) % 31))) & 0xff;
        },
      ];
      for (final mutate in mutations) {
        final zlib = Uint8List.fromList(validZlib);
        mutate(zlib);
        _expectPngError(
          () => _validate(makeTestPng(TestPngInput(width: 2, height: 2, zlib: zlib))),
        );
      }
      _expectPngError(
        () => _validate(
          makeTestPng(
            TestPngInput(
              width: 2,
              height: 2,
              zlib: Uint8List.sublistView(validZlib, 0, 5),
            ),
          ),
        ),
      );
    });

    test('honors a caller-lowered byte budget and validates checksum authorities', () {
      final png = makeTestPng(TestPngInput(width: 2, height: 2));
      _expectPngError(
        () => validatePngProfile(
          PngProfileValidationInput(
            png: png,
            expectedWidth: 2,
            expectedHeight: 2,
            options: FormatOptions(
              budgets: {'maxPngBytes': png.length - 1},
            ),
          ),
        ),
        FormatErrorCode.budgetExceeded,
      );
      final vector = Uint8List.fromList(utf8.encode('123456789'));
      expect(crc32(vector), equals(0xcbf43926));
      expect(crc32(vector), equals(testCrc32(vector)));
      expect(adler32(vector), equals(testAdler32(vector)));
    });
  });
}

PngDecodePlan _validate(Uint8List png) {
  return validatePngProfile(
    PngProfileValidationInput(png: png, expectedWidth: 2, expectedHeight: 2),
  );
}

class _CanonicalParts {
  _CanonicalParts({
    required this.ihdr,
    required this.srgb,
    required this.idat,
    required this.iend,
    required this.zlib,
  });

  final Uint8List ihdr;
  final Uint8List srgb;
  final Uint8List idat;
  final Uint8List iend;
  final Uint8List zlib;

  Uint8List byKey(String key) {
    switch (key) {
      case 'ihdr':
        return ihdr;
      case 'srgb':
        return srgb;
      case 'idat':
        return idat;
      case 'iend':
        return iend;
      default:
        throw ArgumentError('unknown canonical part $key');
    }
  }
}

_CanonicalParts _canonicalParts() {
  const width = 2;
  const height = 2;
  final ihdrPayload = Uint8List(13);
  writeUint32Be(ihdrPayload, 0, width);
  writeUint32Be(ihdrPayload, 4, height);
  ihdrPayload.setRange(8, 13, const [8, 6, 0, 0, 0]);
  final filtered = Uint8List(height * (1 + width * 4));
  final zlib = storedZlib(filtered);
  return _CanonicalParts(
    ihdr: chunk('IHDR', ihdrPayload),
    srgb: chunk('sRGB', Uint8List.fromList(const [0])),
    idat: chunk('IDAT', zlib),
    iend: chunk('IEND', Uint8List(0)),
    zlib: zlib,
  );
}

void _rewriteChunkCrc(Uint8List png, int chunkOffset) {
  final length = readUint32Be(png, chunkOffset);
  writeUint32Be(
    png,
    chunkOffset + 8 + length,
    testCrc32(Uint8List.sublistView(png, chunkOffset + 4, chunkOffset + 8 + length)),
  );
}

FormatError _expectPngError(
  Object? Function() action, [
  FormatErrorCode code = FormatErrorCode.pngEnvelopeInvalid,
]) {
  try {
    action();
  } catch (error) {
    expect(error, isA<FormatError>());
    expect((error as FormatError).code, equals(code));
    return error;
  }
  fail('expected PNG validation failure');
}
