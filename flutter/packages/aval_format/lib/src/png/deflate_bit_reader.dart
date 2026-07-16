/// LSB-first bounded bit reader for RFC 1951 DEFLATE streams.
///
/// Dart port of `packages/format/src/png/deflate-bit-reader.ts`. The TS
/// constructor's runtime `instanceof Uint8Array` check is dropped because
/// Dart's `Uint8List` parameter type enforces it at compile time; the
/// `Number.isSafeInteger` guard on `workLimit` is likewise unnecessary since
/// Dart's `int` has no fractional/NaN states, so only the `>= 1` bound is
/// kept.
library;

import 'dart:typed_data';

import '../errors.dart';

class DeflateBitReader {
  DeflateBitReader(this._bytes, this._workLimit) {
    if (_workLimit < 1) {
      _fail('DEFLATE work limit must be a positive safe integer');
    }
  }

  final Uint8List _bytes;
  final int _workLimit;
  int _bitOffset = 0;
  int _work = 0;

  int get work => _work;

  int readBits(int count, String label) {
    if (count < 0 || count > 24) {
      _fail('$label bit count is invalid');
    }
    var value = 0;
    for (var bit = 0; bit < count; bit += 1) {
      if (_bitOffset >= _bytes.length * 8) {
        _fail('$label is truncated', _bytes.length);
      }
      _charge(1);
      final byte = _bytes[_bitOffset ~/ 8];
      value |= ((byte >> (_bitOffset & 7)) & 1) << bit;
      _bitOffset += 1;
    }
    return value;
  }

  void alignToByte(String label) {
    final remainder = _bitOffset & 7;
    if (remainder == 0) return;
    final padding = readBits(8 - remainder, '$label padding');
    if (padding != 0) _fail('$label padding bits must be zero');
  }

  void finish() {
    alignToByte('terminal DEFLATE');
    if (_bitOffset != _bytes.length * 8) {
      _fail('DEFLATE contains trailing bytes', _bitOffset ~/ 8);
    }
  }

  void decodedSymbol() => _charge(1);

  void copiedOutputByte() => _charge(1);

  void _charge(int amount) {
    if (_work > _workLimit - amount) {
      _fail('DEFLATE work limit exceeded');
    }
    _work += amount;
  }
}

Never deflateInvalid(String message, [int? offset]) => _fail(message, offset);

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.pngDeflateInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}
