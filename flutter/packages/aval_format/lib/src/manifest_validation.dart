/// Shared manifest schema validation primitives.
///
/// Dart port of `packages/format/src/manifest-validation.ts`. Manifest input
/// values are represented as plain `Object?` / `Map<String, Object?>` /
/// `List<Object?>`, mirroring how the TS source treats `unknown` JSON input
/// before it is validated into the typed `model.dart` classes.
library;

import 'constants.dart' show identifierPattern, sha256HexPattern;
import 'errors.dart';
import 'model.dart' show ResidencyEndpointV01;
import 'utf8.dart' show utf8ByteLength;

Map<String, Object?> record(Object? value, String path) {
  if (value is! Map) {
    invalid(path, 'must be an object');
  }
  return value.map((key, v) => MapEntry(key as String, v));
}

List<Object?> array(Object? value, String path) {
  final result = _arrayValue(value, path);
  _requireDenseArray(result, path);
  return result;
}

List<Object?> _arrayValue(Object? value, String path) {
  if (value is! List) {
    invalid(path, 'must be an array');
  }
  return value;
}

void _requireDenseArray(List<Object?> value, String path) {
  // Dart Lists are always dense; this mirrors the TS sparse-array check as a
  // no-op guard kept for structural parity with the source.
}

List<Object?> boundedArray(
  Object? value,
  String path,
  int minimum,
  int maximum,
) {
  final result = _arrayValue(value, path);
  if (result.length < minimum || result.length > maximum) {
    invalid(path, 'must contain between $minimum and $maximum entries');
  }
  _requireDenseArray(result, path);
  return result;
}

List<Object?> tuple(Object? value, int length, String path) {
  final result = _arrayValue(value, path);
  if (result.length != length) {
    invalid(path, 'must contain exactly $length entries');
  }
  _requireDenseArray(result, path);
  return result;
}

void exactKeys(
  Map<String, Object?> value,
  List<String> required, [
  String path = '',
  List<String> optional = const [],
]) {
  final allowed = {...required, ...optional};
  for (final key in value.keys) {
    if (!allowed.contains(key)) {
      invalid(path, 'contains unknown field ${quote(key)}');
    }
  }
  for (final key in required) {
    if (!owns(value, key)) {
      invalid('$path.$key', 'is required');
    }
  }
}

bool owns(Map<String, Object?> value, String key) => value.containsKey(key);

String generatorString(Object? value, String path) {
  if (value is! String) {
    invalid(path, 'must be a string');
  }
  for (var index = 0; index < value.length; index += 1) {
    if (value.codeUnitAt(index) <= 0x1f) {
      invalid(path, 'must not contain C0 controls');
    }
  }
  final length = utf8ByteLength(value, (message, [offset]) {
    invalid(path, 'contains a lone surrogate');
  });
  if (length < 1 || length > 128) {
    invalid(path, 'must contain between 1 and 128 UTF-8 bytes');
  }
  return value;
}

String identifier(Object? value, String path) {
  if (value is! String || !identifierPattern.hasMatch(value)) {
    invalid(path, 'must match ${identifierPattern.pattern}');
  }
  return value;
}

String digest(Object? value, String path) {
  if (value is! String || !sha256HexPattern.hasMatch(value)) {
    invalid(path, 'must be a lowercase 64-character SHA-256 hexadecimal string');
  }
  return value;
}

int positiveInteger(Object? value, String path, [int maximum = _maxSafeInteger]) {
  return integerInRange(value, path, 1, maximum);
}

int nonNegativeInteger(Object? value, String path) {
  return integerInRange(value, path, 0, _maxSafeInteger);
}

const int _maxSafeInteger = 9007199254740991;

int integerInRange(Object? value, String path, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    invalid(path, 'must be a safe integer from $minimum to $maximum');
  }
  return value;
}

T literal<T>(Object? value, T expected, String path) {
  if (value != expected) {
    invalid(path, 'must be ${quote(expected.toString())}');
  }
  return expected;
}

String oneOf(Object? value, List<String> choices, String path) {
  if (value is! String || !choices.contains(value)) {
    invalid(path, 'must be one of ${choices.map(quote).join(', ')}');
  }
  return value;
}

/// Generic over any type with a string identifier, matching the TS
/// structural type `readonly { readonly id: string }[]`.
void requireIdOrder<T>(List<T> values, String Function(T) idOf, String path) {
  requireStringOrder(values.map(idOf).toList(), path);
}

void requireStringOrder(List<String> values, String path) {
  for (var index = 1; index < values.length; index += 1) {
    if (compareAscii(values[index - 1], values[index]) >= 0) {
      invalid(path, 'must be sorted by ID and contain no duplicates');
    }
  }
}

void requireNumberOrder(List<int> values, String path) {
  for (var index = 1; index < values.length; index += 1) {
    if (values[index - 1] >= values[index]) {
      invalid(path, 'must be numerically sorted and unique');
    }
  }
}

int compareEndpoint(ResidencyEndpointV01 a, ResidencyEndpointV01 b) {
  final byState = compareAscii(a.state, b.state);
  return byState != 0 ? byState : compareAscii(a.port, b.port);
}

int compareAscii(String a, String b) => a == b ? 0 : (a.compareTo(b) < 0 ? -1 : 1);

String quote(String value) => '"$value"';

Never invalid(String path, String message) {
  throw FormatError(
    FormatErrorCode.manifestInvalid,
    '$path $message',
    FormatErrorDetails(path: path),
  );
}
