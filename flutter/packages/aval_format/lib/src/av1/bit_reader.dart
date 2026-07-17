/// Bounded MSB-first AV1 syntax reader.
///
/// Dart port of `packages/format/src/av1/bit-reader.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';

/// Bounded MSB-first AV1 syntax reader.
class Av1BitReader {
  Av1BitReader(this._bytes, this._path);

  final Uint8List _bytes;
  final String _path;
  int _bitOffset = 0;

  int get bitOffset => _bitOffset;

  int get bitsRemaining => _bytes.length * 8 - _bitOffset;

  bool readBit(String label) {
    if (_bitOffset >= _bytes.length * 8) {
      _fail('truncated $label');
    }
    final byte = _bytes[_bitOffset ~/ 8];
    final shift = 7 - (_bitOffset % 8);
    _bitOffset += 1;
    return ((byte >> shift) & 1) == 1;
  }

  int readBits(int width, String label) {
    if (width < 0 || width > 32) {
      _fail('invalid bit width for $label');
    }
    if (bitsRemaining < width) _fail('truncated $label');
    var value = 0;
    for (var index = 0; index < width; index += 1) {
      value = value * 2 + (readBit(label) ? 1 : 0);
    }
    return value;
  }

  void readTrailingBits() {
    if (!readBit('trailing_one_bit')) {
      _fail('trailing_one_bit must equal one');
    }
    while (bitsRemaining > 0) {
      if (readBit('trailing_zero_bit')) {
        _fail('trailing_zero_bit must equal zero');
      }
    }
  }

  Never _fail(String message) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AV1 $message',
      FormatErrorDetails(path: _path, offset: _bitOffset ~/ 8),
    );
  }
}
