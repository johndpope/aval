// Dart port of packages/format/test/utf8.test.ts.
import 'dart:typed_data';

import 'package:aval_format/src/utf8.dart';
import 'package:test/test.dart';

Never _rejectUnicode(String message, [int? offset]) {
  throw Exception('$message@$offset');
}

void main() {
  group('UTF-8 scalar primitives', () {
    test('iterates and encodes every UTF-8 width without platform codecs', () {
      const value = 'Aé€😀';

      expect(utf8ByteLength(value, _rejectUnicode), 10);
      expect(
        encodeUtf8String(value, _rejectUnicode),
        [0x41, 0xc3, 0xa9, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x98, 0x80],
      );
      final scalar = readStringScalar(value, 3, _rejectUnicode);
      expect(scalar.codePoint, 0x1f600);
      expect(scalar.width, 2);
    });

    test('strictly decodes scalars and reports the failing byte', () {
      final good = readUtf8Scalar(Uint8List.fromList([0xe2, 0x82, 0xac]), 0, _rejectUnicode);
      expect(good.codePoint, 0x20ac);
      expect(good.width, 3);

      expect(
        () => readUtf8Scalar(Uint8List.fromList([0xe2, 0x28, 0xa1]), 0, _rejectUnicode),
        throwsA(predicate((e) => e.toString().contains('Invalid UTF-8 continuation byte@1'))),
      );
      expect(
        () => readUtf8Scalar(Uint8List.fromList([0xed, 0xa0, 0x80]), 0, _rejectUnicode),
        throwsA(predicate((e) => e.toString().contains('Invalid UTF-8 scalar value@0'))),
      );
    });

    test('rejects both forms of unpaired UTF-16 surrogate', () {
      expect(
        () => utf8ByteLength('\ud800', _rejectUnicode),
        throwsA(predicate((e) => e.toString().contains('String contains a lone high surrogate@0'))),
      );
      expect(
        () => utf8ByteLength('\udc00', _rejectUnicode),
        throwsA(predicate((e) => e.toString().contains('String contains a lone low surrogate@0'))),
      );
    });

    test('compares byte strings unsigned and treats a prefix as smaller', () {
      expect(compareBytes([0x7f], [0x80]), lessThan(0));
      expect(compareBytes([1], [1, 0]), lessThan(0));
      expect(compareBytes([2], [1, 255]), greaterThan(0));
    });
  });
}
