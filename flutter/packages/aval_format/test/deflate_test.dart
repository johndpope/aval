/// Dart port of `packages/format/test/deflate.test.ts`.
///
/// The TS source uses `node:zlib`'s `deflateRawSync` purely to generate real
/// compressed test vectors (stored/fixed/dynamic Huffman blocks) to exercise
/// the hand-rolled inflater under test; it is never used by production code.
/// This Dart port makes the same pragmatic test-only choice with `dart:io`'s
/// `ZLibEncoder(raw: true, ...)` (an SDK library, not a pub package, and
/// never linked into `lib/src/png/*.dart`), which supports the same
/// raw-DEFLATE, level, and strategy (`Z_FIXED`) knobs as `deflateRawSync`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/png/deflate.dart';
import 'package:test/test.dart';

void main() {
  group('bounded RFC 1951 inflater', () {
    for (final kind in const ['stored', 'fixed', 'dynamic']) {
      test('inflates independently generated $kind blocks', () {
        final source = Uint8List.fromList(
          List<int>.generate(
            4097,
            (index) => (index * 37 + (index ~/ 11) * 19) & 0xff,
          ),
        );
        final encoder = ZLibEncoder(
          raw: true,
          level: kind == 'stored' ? 0 : (kind == 'dynamic' ? 9 : 6),
          strategy: kind == 'fixed'
              ? ZLibOption.strategyFixed
              : ZLibOption.strategyDefault,
        );
        final raw = Uint8List.fromList(encoder.convert(source));
        expect(
          (raw[0] >> 1) & 0x3,
          equals(kind == 'stored' ? 0 : (kind == 'fixed' ? 1 : 2)),
        );
        expect(
          inflateDeflate(
            DeflateInflateInput(
              deflate: raw,
              expectedOutputLength: source.length,
            ),
          ),
          equals(source),
        );
      });
    }

    test("inflates the compiler's multi-block stored shape beyond 65,535 bytes", () {
      final source = Uint8List.fromList(
        List<int>.generate(70000, (index) => index & 0xff),
      );
      final raw = Uint8List.fromList(
        ZLibEncoder(raw: true, level: 0).convert(source),
      );
      expect(
        inflateDeflate(
          DeflateInflateInput(deflate: raw, expectedOutputLength: source.length),
        ),
        equals(source),
      );
    });

    test('inflates output above the former 2 MiB ceiling', () {
      final source = Uint8List(2 * 1024 * 1024 + 1)..fillRange(0, 2 * 1024 * 1024 + 1, 0x5a);
      final raw = Uint8List.fromList(
        ZLibEncoder(raw: true, level: 0).convert(source),
      );
      expect(
        inflateDeflate(
          DeflateInflateInput(deflate: raw, expectedOutputLength: source.length),
        ),
        equals(source),
      );
    });

    test('rejects invalid stored complements and output overruns', () {
      final valid = Uint8List.fromList(const [1, 3, 0, 0xfc, 0xff, 1, 2, 3]);
      expect(
        inflateDeflate(DeflateInflateInput(deflate: valid, expectedOutputLength: 3)),
        equals(Uint8List.fromList(const [1, 2, 3])),
      );
      final complement = Uint8List.fromList(valid);
      complement[3] = complement[3] ^ 1;
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: complement, expectedOutputLength: 3),
        ),
      );
      final padding = Uint8List.fromList(valid);
      padding[0] = padding[0] | 0x08;
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: padding, expectedOutputLength: 3),
        ),
      );
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: valid, expectedOutputLength: 2),
        ),
      );
    });

    test('rejects reserved block/literal/distance symbols and missing history', () {
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: Uint8List.fromList(const [0x07]),
            expectedOutputLength: 0,
          ),
        ),
      );
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: _fixedBlock(const [286, 256]),
            expectedOutputLength: 0,
          ),
        ),
      );
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: _fixedLengthDistanceBlock(257, 30),
            expectedOutputLength: 3,
          ),
        ),
      );
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: _fixedLengthDistanceBlock(257, 0),
            expectedOutputLength: 3,
          ),
        ),
      );
    });

    test('rejects empty, oversubscribed, incomplete, and leading-repeat dynamic trees', () {
      for (final raw in [
        _dynamicHeader(const [0, 0, 0, 0]),
        _dynamicHeader(const [1, 1, 1, 1]),
        _dynamicHeader(const [2, 2, 0, 0]),
        _dynamicLeadingRepeat16(),
        _dynamicRepeatOverflow(),
      ]) {
        _expectDeflateError(
          () => inflateDeflate(
            DeflateInflateInput(deflate: raw, expectedOutputLength: 0),
          ),
        );
      }
    });

    test('accepts the RFC 1951 empty distance alphabet for a literal-only block', () {
      final source = Uint8List(257);
      expect(
        inflateDeflate(
          DeflateInflateInput(
            deflate: _dynamicLiteralOnlyBlock(source.length),
            expectedOutputLength: source.length,
          ),
        ),
        equals(source),
      );
    });

    test('rejects a length symbol when the dynamic distance alphabet is empty', () {
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: _dynamicLengthWithoutDistanceBlock(),
            expectedOutputLength: 3,
          ),
        ),
      );
    });

    test('requires EOB, a final block, zero terminal pad bits, and no trailing byte', () {
      final empty = _fixedBlock(const [256]);
      expect(
        inflateDeflate(DeflateInflateInput(deflate: empty, expectedOutputLength: 0)),
        equals(Uint8List(0)),
      );

      final missingEob = _fixedBlock(const [65], includeEob: false);
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: missingEob, expectedOutputLength: 1),
        ),
      );

      final nonfinalStored = Uint8List.fromList(const [0, 0, 0, 0xff, 0xff]);
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: nonfinalStored, expectedOutputLength: 0),
        ),
      );

      final nonzeroPad = Uint8List.fromList(empty);
      nonzeroPad[nonzeroPad.length - 1] = nonzeroPad[nonzeroPad.length - 1] | 0x80;
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: nonzeroPad, expectedOutputLength: 0),
        ),
      );

      final trailing = Uint8List(empty.length + 1);
      trailing.setRange(0, empty.length, empty);
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(deflate: trailing, expectedOutputLength: 0),
        ),
      );
    });

    test('rejects short/long output and enforces the frozen work formula', () {
      final source = Uint8List.fromList(utf8.encode('bounded output'));
      final raw = Uint8List.fromList(ZLibEncoder(raw: true).convert(source));
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: raw,
            expectedOutputLength: source.length - 1,
          ),
        ),
      );
      _expectDeflateError(
        () => inflateDeflate(
          DeflateInflateInput(
            deflate: raw,
            expectedOutputLength: source.length + 1,
          ),
        ),
      );
      expect(calculateDeflateWorkLimit(10, 20), equals(32 * 30 + 4096));
      _expectDeflateError(
        () => calculateDeflateWorkLimit(maxSafeIntegerForTest, 1),
      );
      _expectDeflateError(
        () => inflateDeflateWithLimit(
          DeflateInflateInput(deflate: raw, expectedOutputLength: source.length),
          5,
        ),
      );
      // Note: the TS source additionally asserts that `inflateDeflate(null)`
      // and `inflateDeflate({ deflate: null, ... })` raise PNG_DEFLATE_INVALID
      // at runtime. Dart's `DeflateInflateInput` has non-nullable required
      // fields, so passing `null` for either is a compile-time error rather
      // than a runtime condition; those two assertions have no Dart
      // equivalent and are intentionally omitted.
    });
  });
}

/// `Number.MAX_SAFE_INTEGER`, duplicated locally so this test file has no
/// dependency on package internals beyond the public `png/deflate.dart` API.
const int maxSafeIntegerForTest = 9007199254740991;

Uint8List _dynamicHeader(List<int> codeLengths) {
  final writer = _LsbBitWriter()
    ..bits(1, 1).bits(2, 2) // final dynamic block
    ..bits(0, 5).bits(0, 5).bits(0, 4); // 257, 1, 4
  for (final length in codeLengths) {
    writer.bits(length, 3);
  }
  return writer.finish();
}

Uint8List _dynamicLeadingRepeat16() {
  final writer = _LsbBitWriter()
    ..bits(1, 1).bits(2, 2)
    ..bits(0, 5).bits(0, 5).bits(0, 4);
  // Order is 16,17,18,0: symbols 16 and 0 form a complete one-bit tree.
  writer.bits(1, 3).bits(0, 3).bits(0, 3).bits(1, 3);
  writer.bits(1, 1); // symbol 16 before any prior length
  return writer.finish();
}

Uint8List _dynamicRepeatOverflow() {
  final writer = _LsbBitWriter()
    ..bits(1, 1).bits(2, 2)
    ..bits(0, 5).bits(0, 5).bits(0, 4);
  // Symbols 18 and 0 form a complete one-bit code-length tree.
  writer.bits(0, 3).bits(0, 3).bits(1, 3).bits(1, 3);
  writer.bits(1, 1).bits(127, 7); // 138 zeros
  writer.bits(1, 1).bits(110, 7); // 121 more exceeds total 258
  return writer.finish();
}

Uint8List _dynamicLiteralOnlyBlock(int literalCount) {
  final writer = _dynamicZeroOneLengthHeader(257);
  _writeZeroOneCodeLengths(
    writer,
    List<int>.generate(257, (symbol) => symbol == 0 || symbol == 256 ? 1 : 0),
    const [0],
  );
  for (var index = 0; index < literalCount; index += 1) {
    writer.bits(0, 1); // literal zero
  }
  writer.bits(1, 1); // end-of-block 256
  return writer.finish();
}

Uint8List _dynamicLengthWithoutDistanceBlock() {
  final writer = _dynamicZeroOneLengthHeader(258);
  _writeZeroOneCodeLengths(
    writer,
    List<int>.generate(258, (symbol) => symbol == 256 || symbol == 257 ? 1 : 0),
    const [0],
  );
  writer.bits(1, 1); // length symbol 257; no distance alphabet follows
  return writer.finish();
}

_LsbBitWriter _dynamicZeroOneLengthHeader(int literalCodeCount) {
  final writer = _LsbBitWriter()
    ..bits(1, 1).bits(2, 2) // final dynamic block
    ..bits(literalCodeCount - 257, 5).bits(0, 5).bits(14, 4);
  const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1];
  for (final symbol in order) {
    writer.bits(symbol == 0 || symbol == 1 ? 1 : 0, 3);
  }
  return writer;
}

void _writeZeroOneCodeLengths(
  _LsbBitWriter writer,
  List<int> literalLengths,
  List<int> distanceLengths,
) {
  // Code-length symbols zero and one form the complete one-bit alphabet.
  for (final length in [...literalLengths, ...distanceLengths]) {
    writer.bits(length, 1);
  }
}

Uint8List _fixedBlock(List<int> symbols, {bool includeEob = true}) {
  final writer = _LsbBitWriter()..bits(1, 1).bits(1, 2);
  for (final symbol in symbols) {
    _writeFixedLiteral(writer, symbol);
  }
  if (includeEob && (symbols.isEmpty || symbols.last != 256)) {
    _writeFixedLiteral(writer, 256);
  }
  return writer.finish();
}

Uint8List _fixedLengthDistanceBlock(int lengthSymbol, int distanceSymbol) {
  final writer = _LsbBitWriter()..bits(1, 1).bits(1, 2);
  _writeFixedLiteral(writer, lengthSymbol);
  writer.bits(_reverseBits(distanceSymbol, 5), 5);
  _writeFixedLiteral(writer, 256);
  return writer.finish();
}

void _writeFixedLiteral(_LsbBitWriter writer, int symbol) {
  int code;
  int length;
  if (symbol <= 143) {
    code = 0x30 + symbol;
    length = 8;
  } else if (symbol <= 255) {
    code = 0x190 + symbol - 144;
    length = 9;
  } else if (symbol <= 279) {
    code = symbol - 256;
    length = 7;
  } else {
    code = 0xc0 + symbol - 280;
    length = 8;
  }
  writer.bits(_reverseBits(code, length), length);
}

int _reverseBits(int value, int width) {
  var result = 0;
  for (var index = 0; index < width; index += 1) {
    result = (result << 1) | ((value >> index) & 1);
  }
  return result;
}

class _LsbBitWriter {
  final List<int> _bits = <int>[];

  _LsbBitWriter bits(int value, int count) {
    for (var bit = 0; bit < count; bit += 1) {
      _bits.add((value >> bit) & 1);
    }
    return this;
  }

  Uint8List finish() {
    final bytes = Uint8List((_bits.length / 8).ceil());
    for (var index = 0; index < _bits.length; index += 1) {
      bytes[index ~/ 8] |= _bits[index] << (index & 7);
    }
    return bytes;
  }
}

void _expectDeflateError(Object? Function() action) {
  try {
    action();
  } catch (error) {
    expect(error, isA<FormatError>());
    expect(
      (error as FormatError).code,
      equals(FormatErrorCode.pngDeflateInvalid),
    );
    return;
  }
  fail('expected DEFLATE failure');
}
