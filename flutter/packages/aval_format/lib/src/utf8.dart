/// Strict UTF-8 <-> UTF-16 codecs used by the canonical JSON layer.
///
/// Dart port of `packages/format/src/utf8.ts`. Dart strings are UTF-16 code
/// unit sequences (same as JS), so surrogate-pair handling mirrors the TS
/// source exactly using `String.codeUnitAt`.
library;

class UnicodeScalar {
  const UnicodeScalar({required this.codePoint, required this.width});

  final int codePoint;

  /// Bytes for UTF-8 input, UTF-16 code units for Dart strings.
  final int width;
}

/// Reports a decoding failure. Implementations never return normally.
typedef UnicodeFailure = Never Function(String message, [int? offset]);

bool isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

int decodeSurrogatePair(int high, int low) =>
    0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);

/// Returns the number of bytes in the shortest UTF-8 encoding of a scalar.
int utf8ScalarWidth(int codePoint) {
  if (codePoint <= 0x7f) return 1;
  if (codePoint <= 0x7ff) return 2;
  if (codePoint <= 0xffff) return 3;
  return 4;
}

/// Decodes one strictly well-formed Unicode scalar from UTF-8 bytes.
UnicodeScalar readUtf8Scalar(
  List<int> bytes,
  int offset,
  UnicodeFailure fail,
) {
  if (offset >= bytes.length) {
    fail('Truncated UTF-8 sequence', offset);
  }
  final first = bytes[offset];

  if (first <= 0x7f) return UnicodeScalar(codePoint: first, width: 1);

  int width;
  int minimum;
  int codePoint;

  if (first >= 0xc2 && first <= 0xdf) {
    width = 2;
    minimum = 0x80;
    codePoint = first & 0x1f;
  } else if (first >= 0xe0 && first <= 0xef) {
    width = 3;
    minimum = 0x800;
    codePoint = first & 0x0f;
  } else if (first >= 0xf0 && first <= 0xf4) {
    width = 4;
    minimum = 0x10000;
    codePoint = first & 0x07;
  } else {
    fail('Invalid UTF-8 leading byte', offset);
  }

  if (offset + width > bytes.length) {
    fail('Truncated UTF-8 sequence', offset);
  }

  for (var index = 1; index < width; index += 1) {
    if (offset + index >= bytes.length) {
      fail('Invalid UTF-8 continuation byte', offset + index);
    }
    final continuation = bytes[offset + index];
    if ((continuation & 0xc0) != 0x80) {
      fail('Invalid UTF-8 continuation byte', offset + index);
    }
    codePoint = (codePoint << 6) | (continuation & 0x3f);
  }

  if (codePoint < minimum ||
      codePoint > 0x10ffff ||
      isHighSurrogate(codePoint) ||
      isLowSurrogate(codePoint)) {
    fail('Invalid UTF-8 scalar value', offset);
  }

  return UnicodeScalar(codePoint: codePoint, width: width);
}

/// Reads one Unicode scalar from a Dart (UTF-16) string.
UnicodeScalar readStringScalar(
  String value,
  int offset,
  UnicodeFailure fail,
) {
  if (offset >= value.length) {
    fail('Unexpected end of string', offset);
  }
  final first = value.codeUnitAt(offset);
  if (!isHighSurrogate(first) && !isLowSurrogate(first)) {
    return UnicodeScalar(codePoint: first, width: 1);
  }
  if (isLowSurrogate(first)) {
    fail('String contains a lone low surrogate', offset);
  }

  if (offset + 1 >= value.length) {
    fail('String contains a lone high surrogate', offset);
  }
  final second = value.codeUnitAt(offset + 1);
  if (!isLowSurrogate(second)) {
    fail('String contains a lone high surrogate', offset);
  }
  return UnicodeScalar(
    codePoint: decodeSurrogatePair(first, second),
    width: 2,
  );
}

/// Appends the shortest UTF-8 encoding of a Unicode scalar.
void pushUtf8Scalar(List<int> target, int codePoint) {
  if (codePoint <= 0x7f) {
    target.add(codePoint);
  } else if (codePoint <= 0x7ff) {
    target.add(0xc0 | (codePoint >> 6));
    target.add(0x80 | (codePoint & 0x3f));
  } else if (codePoint <= 0xffff) {
    target.add(0xe0 | (codePoint >> 12));
    target.add(0x80 | ((codePoint >> 6) & 0x3f));
    target.add(0x80 | (codePoint & 0x3f));
  } else {
    target.add(0xf0 | (codePoint >> 18));
    target.add(0x80 | ((codePoint >> 12) & 0x3f));
    target.add(0x80 | ((codePoint >> 6) & 0x3f));
    target.add(0x80 | (codePoint & 0x3f));
  }
}

/// Counts UTF-8 bytes while rejecting unpaired UTF-16 surrogates.
int utf8ByteLength(String value, UnicodeFailure fail) {
  var length = 0;
  var offset = 0;
  while (offset < value.length) {
    final scalar = readStringScalar(value, offset, fail);
    length += utf8ScalarWidth(scalar.codePoint);
    offset += scalar.width;
  }
  return length;
}

/// Encodes a Dart string as strict UTF-8.
List<int> encodeUtf8String(String value, UnicodeFailure fail) {
  final bytes = <int>[];
  var offset = 0;
  while (offset < value.length) {
    final scalar = readStringScalar(value, offset, fail);
    pushUtf8Scalar(bytes, scalar.codePoint);
    offset += scalar.width;
  }
  return bytes;
}

/// Compares byte strings using unsigned lexicographic order.
int compareBytes(List<int> left, List<int> right) {
  final length = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < length; index += 1) {
    final leftByte = left[index];
    final rightByte = right[index];
    if (leftByte != rightByte) return leftByte - rightByte;
  }
  return left.length - right.length;
}
