/// Canonical JSON codec: one legal byte-serialization per value.
///
/// Dart port of `packages/format/src/canonical-json.ts`. Values are
/// represented with plain Dart `Object?` (String, bool, int, List<Object?>,
/// Map<String, Object?>) rather than a dedicated sealed type, mirroring the
/// TS `CanonicalJsonValue` structural union (`null | boolean | number |
/// string | array | object`) — Dart's dynamic-typed collections are the
/// direct structural analogue here, and the parser/writer below are the
/// sole authority on shape the same way they are in TS.
library;

import 'dart:typed_data';

import 'checked_integer.dart' show maxSafeInteger;
import 'constants.dart' show resolveFormatBudgets;
import 'errors.dart';
import 'model.dart' show FormatBudgets, FormatOptions;
import 'utf8.dart';

class CanonicalJsonWriteLimits {
  const CanonicalJsonWriteLimits({
    required this.maxBytes,
    required this.maxDepth,
    required this.maxNodes,
    required this.maxStringBytes,
  });

  final int maxBytes;
  final int maxDepth;
  final int maxNodes;
  final int maxStringBytes;
}

class _WriterBudgets {
  const _WriterBudgets({
    required this.maxManifestBytes,
    required this.maxJsonDepth,
    required this.maxJsonNodes,
    required this.maxJsonStringBytes,
  });

  final int maxManifestBytes;
  final int maxJsonDepth;
  final int maxJsonNodes;
  final int maxJsonStringBytes;
}

const CanonicalJsonWriteLimits _maxCanonicalWriteLimits = CanonicalJsonWriteLimits(
  maxBytes: 9007199254740991,
  maxDepth: 128,
  maxNodes: 9007199254740991,
  maxStringBytes: 32 * 1024 * 1024,
);
const int _writerPageBytes = 64 * 1024;

const Set<String> _dangerousKeys = {'__proto__', 'prototype', 'constructor'};

Never _fail(FormatErrorCode code, String message, [int? offset]) {
  throw FormatError(
    code,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}

Never _failInputUnicode(String message, [int? offset]) =>
    _fail(FormatErrorCode.inputInvalid, message);

Never _failJsonUnicode(String message, [int? offset]) =>
    _fail(FormatErrorCode.jsonInvalid, message, offset);

List<int> _encodeBoundedKey(String value, int maximum) {
  var byteLength = 0;
  var offset = 0;
  while (offset < value.length) {
    final scalar = readStringScalar(value, offset, _failInputUnicode);
    final width = utf8ScalarWidth(scalar.codePoint);
    if (byteLength > maximum - width) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON string budget exceeded');
    }
    byteLength += width;
    offset += scalar.width;
  }
  return encodeUtf8String(value, _failInputUnicode);
}

/// Compares decoded strings using unsigned lexicographic UTF-8 byte order.
int compareUtf8Strings(String left, String right) {
  try {
    return compareBytes(
      encodeUtf8String(left, _failInputUnicode),
      encodeUtf8String(right, _failInputUnicode),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'Could not compare UTF-8 strings',
    );
  }
}

class _CanonicalJsonParser {
  _CanonicalJsonParser(this._bytes, this._budgets);

  final Uint8List _bytes;
  final FormatBudgets _budgets;
  int _offset = 0;
  int _nodes = 0;

  Object? parse() {
    if (_bytes.length >= 3 &&
        _bytes[0] == 0xef &&
        _bytes[1] == 0xbb &&
        _bytes[2] == 0xbf) {
      _fail(FormatErrorCode.jsonInvalid, 'A UTF-8 BOM is not permitted', 0);
    }

    _skipWhitespace();
    final value = _parseValue(1);
    _skipWhitespace();
    if (_offset != _bytes.length) {
      _fail(FormatErrorCode.jsonInvalid, 'Unexpected trailing JSON data', _offset);
    }
    return value;
  }

  int? _byteAt(int offset) => offset < _bytes.length ? _bytes[offset] : null;

  Object? _parseValue(int depth) {
    if (depth > _budgets.maxJsonDepth) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON depth budget exceeded', _offset);
    }
    _nodes += 1;
    if (_nodes > _budgets.maxJsonNodes) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON node budget exceeded', _offset);
    }

    final byte = _byteAt(_offset);
    switch (byte) {
      case 0x22:
        return _parseString();
      case 0x5b:
        return _parseArray(depth);
      case 0x7b:
        return _parseObject(depth);
      case 0x74:
        _parseLiteral('true');
        return true;
      case 0x66:
        _parseLiteral('false');
        return false;
      case 0x6e:
        _parseLiteral('null');
        return null;
      case 0x2d:
      case 0x30:
      case 0x31:
      case 0x32:
      case 0x33:
      case 0x34:
      case 0x35:
      case 0x36:
      case 0x37:
      case 0x38:
      case 0x39:
        return _parseInteger();
      default:
        _fail(FormatErrorCode.jsonInvalid, 'Expected a JSON value', _offset);
    }
  }

  void _parseLiteral(String literal) {
    for (var index = 0; index < literal.length; index += 1) {
      if (_byteAt(_offset + index) != literal.codeUnitAt(index)) {
        _fail(FormatErrorCode.jsonInvalid, 'Invalid JSON literal', _offset + index);
      }
    }
    _offset += literal.length;
  }

  int _parseInteger() {
    final start = _offset;
    final negative = _byteAt(_offset) == 0x2d;
    if (negative) _offset += 1;

    final firstDigit = _byteAt(_offset);
    if (firstDigit == null || firstDigit < 0x30 || firstDigit > 0x39) {
      _fail(FormatErrorCode.jsonInvalid, 'Expected a digit after minus', _offset);
    }

    var magnitude = 0;
    if (firstDigit == 0x30) {
      _offset += 1;
      final next = _byteAt(_offset);
      if (next != null && next >= 0x30 && next <= 0x39) {
        _fail(
          FormatErrorCode.jsonNoncanonical,
          'Leading zeroes are not canonical',
          _offset,
        );
      }
    } else {
      while (true) {
        final byte = _byteAt(_offset);
        if (byte == null || byte < 0x30 || byte > 0x39) break;
        final digit = byte - 0x30;
        if (magnitude > ((maxSafeInteger - digit) / 10).floor()) {
          _fail(FormatErrorCode.integerUnsafe, 'JSON integer is not safe', start);
        }
        magnitude = magnitude * 10 + digit;
        _offset += 1;
      }
    }

    final suffix = _byteAt(_offset);
    if (suffix == 0x2e || suffix == 0x45 || suffix == 0x65) {
      _fail(
        FormatErrorCode.jsonNoncanonical,
        'Fractions and exponents are not canonical integers',
        _offset,
      );
    }
    if (negative && magnitude == 0) {
      _fail(FormatErrorCode.jsonNoncanonical, 'Negative zero is not canonical', start);
    }
    return negative ? -magnitude : magnitude;
  }

  List<Object?> _parseArray(int depth) {
    _offset += 1;
    final values = <Object?>[];
    _skipWhitespace();
    if (_byteAt(_offset) == 0x5d) {
      _offset += 1;
      return values;
    }

    while (true) {
      values.add(_parseValue(depth + 1));
      _skipWhitespace();
      final delimiter = _byteAt(_offset);
      if (delimiter == 0x5d) {
        _offset += 1;
        return values;
      }
      if (delimiter != 0x2c) {
        _fail(
          FormatErrorCode.jsonInvalid,
          'Expected a comma or closing bracket',
          _offset,
        );
      }
      _offset += 1;
      _skipWhitespace();
    }
  }

  Map<String, Object?> _parseObject(int depth) {
    _offset += 1;
    final value = <String, Object?>{};
    final keys = <String>{};
    _skipWhitespace();
    if (_byteAt(_offset) == 0x7d) {
      _offset += 1;
      return value;
    }

    while (true) {
      if (_byteAt(_offset) != 0x22) {
        _fail(FormatErrorCode.jsonInvalid, 'Expected a quoted object key', _offset);
      }
      final keyOffset = _offset;
      final key = _parseString();
      if (_dangerousKeys.contains(key)) {
        _fail(
          FormatErrorCode.jsonDangerousKey,
          'Dangerous object key $key is forbidden',
          keyOffset,
        );
      }
      if (keys.contains(key)) {
        _fail(
          FormatErrorCode.jsonDuplicateKey,
          'Duplicate decoded object key $key',
          keyOffset,
        );
      }
      keys.add(key);

      _skipWhitespace();
      if (_byteAt(_offset) != 0x3a) {
        _fail(FormatErrorCode.jsonInvalid, 'Expected a colon after object key', _offset);
      }
      _offset += 1;
      _skipWhitespace();
      value[key] = _parseValue(depth + 1);
      _skipWhitespace();

      final delimiter = _byteAt(_offset);
      if (delimiter == 0x7d) {
        _offset += 1;
        return value;
      }
      if (delimiter != 0x2c) {
        _fail(
          FormatErrorCode.jsonInvalid,
          'Expected a comma or closing brace',
          _offset,
        );
      }
      _offset += 1;
      _skipWhitespace();
    }
  }

  String _parseString() {
    final start = _offset;
    _offset += 1;
    final scalars = StringBuffer();
    var decodedBytes = 0;

    while (_offset < _bytes.length) {
      final byte = _byteAt(_offset);
      if (byte == null) break;
      if (byte == 0x22) {
        _offset += 1;
        return scalars.toString();
      }
      if (byte == 0x5c) {
        final escaped = _parseEscape();
        decodedBytes += utf8ScalarWidth(escaped);
        _checkStringBudget(decodedBytes, start);
        scalars.writeCharCode(escaped);
        continue;
      }
      if (byte < 0x20) {
        _fail(
          FormatErrorCode.jsonInvalid,
          'Unescaped control character in string',
          _offset,
        );
      }
      final scalar = readUtf8Scalar(_bytes, _offset, _failJsonUnicode);
      decodedBytes += scalar.width;
      _checkStringBudget(decodedBytes, start);
      scalars.writeCharCode(scalar.codePoint);
      _offset += scalar.width;
    }

    _fail(FormatErrorCode.jsonInvalid, 'Unterminated JSON string', start);
  }

  int _parseEscape() {
    final escapeOffset = _offset;
    _offset += 1;
    final escaped = _byteAt(_offset);
    _offset += 1;
    switch (escaped) {
      case 0x22:
        return 0x22;
      case 0x2f:
        return 0x2f;
      case 0x5c:
        return 0x5c;
      case 0x62:
        return 0x08;
      case 0x66:
        return 0x0c;
      case 0x6e:
        return 0x0a;
      case 0x72:
        return 0x0d;
      case 0x74:
        return 0x09;
      case 0x75:
        return _parseUnicodeEscape(escapeOffset);
      default:
        _fail(FormatErrorCode.jsonInvalid, 'Invalid JSON string escape', escapeOffset);
    }
  }

  int _parseUnicodeEscape(int escapeOffset) {
    final first = _readHexQuad(escapeOffset);
    if (isLowSurrogate(first)) {
      _fail(FormatErrorCode.jsonInvalid, 'Lone low surrogate escape', escapeOffset);
    }
    if (!isHighSurrogate(first)) return first;

    if (_byteAt(_offset) != 0x5c || _byteAt(_offset + 1) != 0x75) {
      _fail(FormatErrorCode.jsonInvalid, 'Lone high surrogate escape', escapeOffset);
    }
    _offset += 2;
    final second = _readHexQuad(_offset - 2);
    if (!isLowSurrogate(second)) {
      _fail(FormatErrorCode.jsonInvalid, 'Invalid surrogate pair escape', escapeOffset);
    }
    return decodeSurrogatePair(first, second);
  }

  int _readHexQuad(int escapeOffset) {
    var value = 0;
    for (var index = 0; index < 4; index += 1) {
      final byte = _byteAt(_offset);
      if (byte == null) {
        _fail(FormatErrorCode.jsonInvalid, 'Truncated Unicode escape', escapeOffset);
      }
      int digit;
      if (byte >= 0x30 && byte <= 0x39) {
        digit = byte - 0x30;
      } else if (byte >= 0x41 && byte <= 0x46) {
        digit = byte - 0x41 + 10;
      } else if (byte >= 0x61 && byte <= 0x66) {
        digit = byte - 0x61 + 10;
      } else {
        _fail(FormatErrorCode.jsonInvalid, 'Invalid Unicode escape', _offset);
      }
      value = value * 16 + digit;
      _offset += 1;
    }
    return value;
  }

  void _checkStringBudget(int decodedBytes, int offset) {
    if (decodedBytes > _budgets.maxJsonStringBytes) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON string budget exceeded', offset);
    }
  }

  void _skipWhitespace() {
    while (true) {
      final byte = _byteAt(_offset);
      if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) return;
      _offset += 1;
    }
  }
}

class _EncodedKey {
  const _EncodedKey(this.key, this.bytes);

  final String key;
  final List<int> bytes;
}

class _CanonicalJsonWriter {
  _CanonicalJsonWriter(this._budgets);

  final _WriterBudgets _budgets;
  final List<Uint8List> _pages = [];
  final Set<Object> _active = {};
  Uint8List _current = Uint8List(_writerPageBytes);
  int _currentLength = 0;
  int _byteLength = 0;
  int _nodes = 0;

  Uint8List serialize(Object? value) {
    _writeValue(value, 1);
    final output = Uint8List(_byteLength);
    var offset = 0;
    for (final page in _pages) {
      output.setRange(offset, offset + page.length, page);
      offset += page.length;
    }
    output.setRange(offset, offset + _currentLength, _current);
    return output;
  }

  void _writeValue(Object? value, int depth) {
    if (depth > _budgets.maxJsonDepth) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON depth budget exceeded');
    }
    _nodes += 1;
    if (_nodes > _budgets.maxJsonNodes) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON node budget exceeded');
    }

    if (value == null) {
      _pushAscii('null');
      return;
    }
    if (value is bool) {
      _pushAscii(value ? 'true' : 'false');
      return;
    }
    if (value is String) {
      _writeString(value);
      return;
    }
    if (value is int) {
      if (value == 0 && value.isNegative) {
        _fail(FormatErrorCode.inputInvalid, 'Negative zero is not canonical');
      }
      _pushAscii(value.toString());
      return;
    }
    if (value is double) {
      _fail(
        FormatErrorCode.integerUnsafe,
        'JSON numbers must be safe integers',
      );
    }
    if (value is List) {
      if (_active.contains(value)) {
        _fail(FormatErrorCode.inputInvalid, 'Canonical JSON cannot contain cycles');
      }
      _active.add(value);
      try {
        _writeArray(value, depth);
      } finally {
        _active.remove(value);
      }
      return;
    }
    if (value is Map) {
      if (_active.contains(value)) {
        _fail(FormatErrorCode.inputInvalid, 'Canonical JSON cannot contain cycles');
      }
      _active.add(value);
      try {
        _writeObject(value, depth);
      } finally {
        _active.remove(value);
      }
      return;
    }
    _fail(FormatErrorCode.inputInvalid, 'Value is not representable as canonical JSON');
  }

  void _writeArray(List<Object?> value, int depth) {
    _pushByte(0x5b);
    for (var index = 0; index < value.length; index += 1) {
      if (index != 0) _pushByte(0x2c);
      _writeValue(value[index], depth + 1);
    }
    _pushByte(0x5d);
  }

  void _writeObject(Map<Object?, Object?> value, int depth) {
    final remainingNodes = _budgets.maxJsonNodes - _nodes;
    if (value.length > remainingNodes) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON node budget exceeded');
    }
    final encodedKeys = <_EncodedKey>[];
    var retainedKeyBytes = 0;
    for (final rawKey in value.keys) {
      if (rawKey is! String) {
        _fail(FormatErrorCode.inputInvalid, 'Non-string keys are not canonical JSON');
      }
      if (_dangerousKeys.contains(rawKey)) {
        _fail(
          FormatErrorCode.jsonDangerousKey,
          'Dangerous object key $rawKey is forbidden',
        );
      }
      final bytes = _encodeBoundedKey(rawKey, _budgets.maxJsonStringBytes);
      final remainingManifestBytes = _budgets.maxManifestBytes - _byteLength;
      if (retainedKeyBytes > remainingManifestBytes - bytes.length) {
        _fail(FormatErrorCode.budgetExceeded, 'Manifest byte budget exceeded');
      }
      retainedKeyBytes += bytes.length;
      encodedKeys.add(_EncodedKey(rawKey, bytes));
    }
    encodedKeys.sort((left, right) => compareBytes(left.bytes, right.bytes));

    _pushByte(0x7b);
    for (var index = 0; index < encodedKeys.length; index += 1) {
      final encodedKey = encodedKeys[index];
      if (index != 0) _pushByte(0x2c);
      _writeString(encodedKey.key);
      _pushByte(0x3a);
      _writeValue(value[encodedKey.key], depth + 1);
    }
    _pushByte(0x7d);
  }

  void _writeString(String value) {
    _pushByte(0x22);
    var decodedBytes = 0;
    var offset = 0;
    while (offset < value.length) {
      final scalar = readStringScalar(value, offset, _failInputUnicode);
      final codePoint = scalar.codePoint;
      decodedBytes += utf8ScalarWidth(codePoint);
      if (decodedBytes > _budgets.maxJsonStringBytes) {
        _fail(FormatErrorCode.budgetExceeded, 'JSON string budget exceeded');
      }

      switch (codePoint) {
        case 0x08:
          _pushAscii('\\b');
          break;
        case 0x09:
          _pushAscii('\\t');
          break;
        case 0x0a:
          _pushAscii('\\n');
          break;
        case 0x0c:
          _pushAscii('\\f');
          break;
        case 0x0d:
          _pushAscii('\\r');
          break;
        case 0x22:
          _pushAscii('\\"');
          break;
        case 0x5c:
          _pushAscii('\\\\');
          break;
        default:
          if (codePoint < 0x20) {
            _pushAscii('\\u00${codePoint.toRadixString(16).padLeft(2, '0')}');
          } else {
            _pushScalar(codePoint);
          }
      }
      offset += scalar.width;
    }
    _pushByte(0x22);
  }

  void _pushScalar(int codePoint) {
    final encoded = <int>[];
    pushUtf8Scalar(encoded, codePoint);
    _reserve(encoded.length);
    for (final byte in encoded) {
      _appendByte(byte);
    }
  }

  void _pushAscii(String value) {
    _reserve(value.length);
    for (var index = 0; index < value.length; index += 1) {
      _appendByte(value.codeUnitAt(index));
    }
  }

  void _pushByte(int value) {
    _reserve(1);
    _appendByte(value);
  }

  void _appendByte(int value) {
    if (_currentLength == _current.length) {
      _pages.add(_current);
      _current = Uint8List(_writerPageBytes);
      _currentLength = 0;
    }
    _current[_currentLength] = value;
    _currentLength += 1;
    _byteLength += 1;
  }

  void _reserve(int length) {
    if (_byteLength > _budgets.maxManifestBytes - length) {
      _fail(FormatErrorCode.budgetExceeded, 'Manifest byte budget exceeded');
    }
  }
}

/// Serializes a JSON-compatible value into the one canonical UTF-8 form.
Uint8List serializeCanonicalJson(Object? value, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    return _CanonicalJsonWriter(_toWriterBudgets(budgets)).serialize(value);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'Could not serialize canonical JSON',
    );
  }
}

/// Serializes trusted high-cardinality JSON with the same canonical owner
/// while retaining explicit hard upper limits independent from on-wire
/// budgets.
Uint8List serializeCanonicalJsonWithLimits(
  Object? value,
  CanonicalJsonWriteLimits limits,
) {
  try {
    final budgets = _resolveCanonicalJsonWriteLimits(limits);
    return _CanonicalJsonWriter(budgets).serialize(value);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.inputInvalid,
      'Could not serialize canonical JSON',
    );
  }
}

_WriterBudgets _resolveCanonicalJsonWriteLimits(CanonicalJsonWriteLimits limits) {
  final entries = <String, int>{
    'maxBytes': limits.maxBytes,
    'maxDepth': limits.maxDepth,
    'maxNodes': limits.maxNodes,
    'maxStringBytes': limits.maxStringBytes,
  };
  final maxima = <String, int>{
    'maxBytes': _maxCanonicalWriteLimits.maxBytes,
    'maxDepth': _maxCanonicalWriteLimits.maxDepth,
    'maxNodes': _maxCanonicalWriteLimits.maxNodes,
    'maxStringBytes': _maxCanonicalWriteLimits.maxStringBytes,
  };
  for (final key in entries.keys) {
    final value = entries[key]!;
    final maximum = maxima[key]!;
    if (value < 1 || value > maximum) {
      _fail(
        FormatErrorCode.inputInvalid,
        '$key must be an integer from 1 through $maximum',
      );
    }
  }
  if (limits.maxStringBytes > limits.maxBytes) {
    _fail(FormatErrorCode.inputInvalid, 'maxStringBytes may not exceed maxBytes');
  }
  return _WriterBudgets(
    maxManifestBytes: limits.maxBytes,
    maxJsonDepth: limits.maxDepth,
    maxJsonNodes: limits.maxNodes,
    maxJsonStringBytes: limits.maxStringBytes,
  );
}

_WriterBudgets _toWriterBudgets(FormatBudgets budgets) => _WriterBudgets(
      maxManifestBytes: budgets.maxManifestBytes,
      maxJsonDepth: budgets.maxJsonDepth,
      maxJsonNodes: budgets.maxJsonNodes,
      maxJsonStringBytes: budgets.maxJsonStringBytes,
    );

/// Parses canonical UTF-8 JSON without a general-purpose JSON parser,
/// rejects alternate byte spellings, and returns a value tree matching the
/// exact input bytes.
Object? parseCanonicalJson(Uint8List bytes, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    if (bytes.length > budgets.maxManifestBytes) {
      _fail(FormatErrorCode.budgetExceeded, 'Manifest byte budget exceeded', 0);
    }
    final value = _CanonicalJsonParser(bytes, budgets).parse();
    final canonical = _CanonicalJsonWriter(_toWriterBudgets(budgets)).serialize(value);
    final comparedLength =
        bytes.length < canonical.length ? bytes.length : canonical.length;
    var mismatch = comparedLength;
    for (var index = 0; index < comparedLength; index += 1) {
      if (bytes[index] != canonical[index]) {
        mismatch = index;
        break;
      }
    }
    if (mismatch != comparedLength || bytes.length != canonical.length) {
      _fail(
        FormatErrorCode.jsonNoncanonical,
        'JSON bytes do not match canonical serialization',
        mismatch,
      );
    }
    return value;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.jsonInvalid, 'Could not parse canonical JSON');
  }
}

/// Parses bounded strict UTF-8 JSON while allowing insignificant whitespace
/// and object-key order. Numbers remain safe integers and duplicate/
/// dangerous keys retain the canonical parser's rejection behavior.
Object? parseStrictJson(Uint8List bytes, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    if (bytes.length > budgets.maxManifestBytes) {
      _fail(FormatErrorCode.budgetExceeded, 'JSON byte budget exceeded', 0);
    }
    return _CanonicalJsonParser(bytes, budgets).parse();
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.jsonInvalid, 'Could not parse strict JSON');
  }
}
