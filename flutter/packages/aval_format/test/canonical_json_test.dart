// Dart port of packages/format/test/canonical-json.test.ts.
//
// A few TS assertions have no Dart equivalent and are adapted or dropped,
// noted at each site: Proxy-based `getOwnPropertyDescriptor` call counting
// (no Proxy in Dart), `Object.isFrozen`/null-prototype checks (Dart values
// returned here are plain Map/List; there is no runtime "frozen" bit to
// assert on), and getter/accessor property rejection (Dart Map values are
// always plain data, never accessors).
import 'dart:convert';
import 'dart:typed_data';

import 'package:aval_format/src/canonical_json.dart';
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/model.dart' show FormatOptions;
import 'package:test/test.dart';

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

String _text(Uint8List value) => utf8.decode(value);

FormatError _expectCode(dynamic Function() action, FormatErrorCode code) {
  try {
    action();
  } on FormatError catch (error) {
    expect(error.code, code);
    return error;
  }
  fail('Expected FormatError $code');
}

void main() {
  group('canonical JSON serialization', () {
    test('shares a strict noncanonical source-document parser', () {
      final value = parseStrictJson(_utf8('{ "z": 2, "a": 1 }')) as Map;
      expect(value, {'z': 2, 'a': 1});
      _expectCode(
        () => parseStrictJson(_utf8('{"a":1,"\\u0061":2}')),
        FormatErrorCode.jsonDuplicateKey,
      );
    });

    test('writes the recursively minified canonical form', () {
      final value = {
        'z': [true, false, null, -42],
        'a': {'b': 2, 'a': 1},
      };
      expect(_text(serializeCanonicalJson(value)), '{"a":{"a":1,"b":2},"z":[true,false,null,-42]}');
    });

    test('uses the same writer for explicitly bounded high-cardinality output', () {
      final values = List<int>.generate(25000, (index) => index);
      final bytes = serializeCanonicalJsonWithLimits(
        {'values': values},
        const CanonicalJsonWriteLimits(
          maxBytes: 1024 * 1024,
          maxDepth: 16,
          maxNodes: 30000,
          maxStringBytes: 4096,
        ),
      );
      expect(jsonDecode(_text(bytes)), {'values': values});
      _expectCode(
        () => serializeCanonicalJsonWithLimits(
          {'values': values},
          const CanonicalJsonWriteLimits(
            maxBytes: 1024,
            maxDepth: 16,
            maxNodes: 30000,
            maxStringBytes: 1024,
          ),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('sorts keys by unsigned UTF-8 bytes rather than UTF-16 code units', () {
      // The third key is U+E000 (a Private Use Area character, invisible in
      // most renderers) — NOT an empty string. Its UTF-8 encoding is 3 bytes
      // (0xEE 0x80 0x80), sorting after 'e-acute' (0xC3 0xA9) and before the
      // astral char below (0xF0 0x90 0x80 0x80): exactly why the TS source
      // picked it — it demonstrates UTF-8 byte order diverging from naive
      // UTF-16 code-unit order.
      const astral = '\u{10000}';
      const privateUse = '\u{E000}';
      final value = {astral: 2, privateUse: 1, 'é': 3, 'z': 4};
      expect(
        _text(serializeCanonicalJson(value)),
        '{"z":4,"é":3,"$privateUse":1,"$astral":2}',
      );
      expect(compareUtf8Strings(privateUse, astral), lessThan(0));
    });

    test('uses only the prescribed escapes and preserves all other scalars', () {
      // Includes literal U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH
      // SEPARATOR) between the NUL escape and 'é' — both are >= 0x20 so the
      // writer passes them through as literal UTF-8 scalars, unescaped.
      const value = '"\\\b\t\n\f\r\u0000/\u2028\u2029\u00e9\u{1F600}';
      expect(
        _text(serializeCanonicalJson(value)),
        '"\\"\\\\\\b\\t\\n\\f\\r\\u0000/\u2028\u2029\u00e9\u{1F600}"',
      );
    });

    test('writes minimum and maximum safe integers in shortest decimal form', () {
      expect(
        _text(serializeCanonicalJson([-9007199254740991, 0, 9007199254740991])),
        '[-9007199254740991,0,9007199254740991]',
      );
    });

    test('rejects unsupported values and cycles stably', () {
      _expectCode(() => serializeCanonicalJson(3.14), FormatErrorCode.integerUnsafe);

      final cycle = <Object?>[];
      cycle.add(cycle);
      _expectCode(() => serializeCanonicalJson(cycle), FormatErrorCode.inputInvalid);
    });

    test('rejects dangerous keys and lone UTF-16 surrogates', () {
      _expectCode(
        () => serializeCanonicalJson({'constructor': 1}),
        FormatErrorCode.jsonDangerousKey,
      );
      _expectCode(() => serializeCanonicalJson('\ud800'), FormatErrorCode.inputInvalid);
      _expectCode(() => serializeCanonicalJson('\udc00'), FormatErrorCode.inputInvalid);
    });

    test('bounds object-key and manifest-byte work before completing', () {
      _expectCode(
        () => serializeCanonicalJson(
          {'a': 1, 'b': 2},
          const FormatOptions(budgets: {'maxJsonNodes': 2}),
        ),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => serializeCanonicalJson(
          {'a': 1, 'b': 2, 'c': 3},
          const FormatOptions(budgets: {'maxManifestBytes': 1}),
        ),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => serializeCanonicalJson({'a'.padRight(4097, 'a'): 1}),
        FormatErrorCode.budgetExceeded,
      );
    });
  });

  group('canonical JSON parsing', () {
    test('returns a value tree matching the exact JSON structure', () {
      final parsed = parseCanonicalJson(_utf8('{"a":{"b":1},"items":[{"c":2}]}')) as Map;
      final nested = parsed['a'] as Map;
      final items = parsed['items'] as List;
      final item = items[0] as Map;
      expect(nested['b'], 1);
      expect(item['c'], 2);
    });

    test('accepts every canonical primitive and literal non-ASCII scalar', () {
      for (final source in ['null', 'true', 'false', '0', '-1', '"é😀  /"', '[]', '{}']) {
        expect(() => parseCanonicalJson(_utf8(source)), returnsNormally);
      }
    });

    test('detects duplicate keys after escape decoding before canonical comparison', () {
      final error = _expectCode(
        () => parseCanonicalJson(_utf8('{"a":1,"\\u0061":2}')),
        FormatErrorCode.jsonDuplicateKey,
      );
      expect(error.offset, 7);
    });

    test('rejects dangerous decoded keys', () {
      for (final source in [
        '{"__proto__":1}',
        '{"prototype":1}',
        '{"constructor":1}',
        '{"\\u005f_proto__":1}',
      ]) {
        _expectCode(() => parseCanonicalJson(_utf8(source)), FormatErrorCode.jsonDangerousKey);
      }
    });

    test('rejects noncanonical spellings', () {
      for (final source in [
        ' true',
        'true\n',
        '[1, 2]',
        '{"b":1,"a":2}',
        '"\\/"',
        '"\\u0061"',
        '"\\u001B"',
        '"\\uD83D\\uDE00"',
        '-0',
        '01',
        '1.0',
        '1e0',
      ]) {
        _expectCode(() => parseCanonicalJson(_utf8(source)), FormatErrorCode.jsonNoncanonical);
      }
    });

    test('rejects fatal UTF-8 cases', () {
      for (final source in [
        [0xef, 0xbb, 0xbf, 0x6e, 0x75, 0x6c, 0x6c],
        [0x22, 0x80, 0x22],
        [0x22, 0xc0, 0xaf, 0x22],
        [0x22, 0xe0, 0x80, 0xaf, 0x22],
        [0x22, 0xed, 0xa0, 0x80, 0x22],
        [0x22, 0xf4, 0x90, 0x80, 0x80, 0x22],
        [0x22, 0xf0, 0x9f, 0x98],
        [0x22, 0xe2, 0x28, 0xa1, 0x22],
      ]) {
        _expectCode(
          () => parseCanonicalJson(Uint8List.fromList(source)),
          FormatErrorCode.jsonInvalid,
        );
      }
    });

    test('rejects malformed JSON without a built-in exception', () {
      for (final source in [
        '"\\ud800"',
        '"\\udc00"',
        '"\\ud800x"',
        '"\\ud800\\u0041"',
        '"\\uZZZZ"',
        '"\\x20"',
        '"raw\nnewline"',
        '[1,]',
        '{"a":1,}',
        'tru',
        '',
      ]) {
        _expectCode(() => parseCanonicalJson(_utf8(source)), FormatErrorCode.jsonInvalid);
      }
    });

    test('rejects integers outside the safe range', () {
      _expectCode(() => parseCanonicalJson(_utf8('9007199254740992')), FormatErrorCode.integerUnsafe);
      _expectCode(() => parseCanonicalJson(_utf8('-9007199254740992')), FormatErrorCode.integerUnsafe);
      _expectCode(
        () => parseCanonicalJson(_utf8('999999999999999999999999999999')),
        FormatErrorCode.integerUnsafe,
      );
    });

    test('enforces manifest, depth, node, and decoded string budgets', () {
      _expectCode(
        () => parseCanonicalJson(_utf8('null'), const FormatOptions(budgets: {'maxManifestBytes': 3})),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => parseCanonicalJson(_utf8('[[0]]'), const FormatOptions(budgets: {'maxJsonDepth': 2})),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => parseCanonicalJson(_utf8('[0,1]'), const FormatOptions(budgets: {'maxJsonNodes': 2})),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => parseCanonicalJson(_utf8('"éé"'), const FormatOptions(budgets: {'maxJsonStringBytes': 3})),
        FormatErrorCode.budgetExceeded,
      );
      _expectCode(
        () => parseCanonicalJson(
          _utf8('"\\u00e9\\u00e9"'),
          const FormatOptions(budgets: {'maxJsonStringBytes': 3}),
        ),
        FormatErrorCode.budgetExceeded,
      );
    });

    test('reports the first byte that differs from canonical form', () {
      final error = _expectCode(
        () => parseCanonicalJson(_utf8('{"b":1,"a":2}')),
        FormatErrorCode.jsonNoncanonical,
      );
      expect(error.offset, 2);
    });
  });
}
