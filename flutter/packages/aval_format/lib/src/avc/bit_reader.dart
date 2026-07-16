/// Bounded MSB-first RBSP bit reader.
///
/// Dart port of `packages/format/src/avc/bit-reader.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import 'failure.dart';

/// Bounded MSB-first RBSP reader.
class RbspBitReader {
  RbspBitReader(this._bytes, this._path, this._absoluteOffset);

  final Uint8List _bytes;
  final String _path;
  final int _absoluteOffset;
  int _bitOffset = 0;

  int get bitOffset => _bitOffset;

  int get bitsRemaining => _bytes.length * 8 - _bitOffset;

  bool readBit(String label) {
    if (_bitOffset >= _bytes.length * 8) {
      _fail('truncated $label');
    }
    final byte = _bytes[_bitOffset ~/ 8];
    final value = (byte >> (7 - (_bitOffset % 8))) & 1;
    _bitOffset += 1;
    return value == 1;
  }

  int readBits(int width, String label) {
    if (width < 0 || width > 32) {
      _fail('invalid bit width while reading $label');
    }
    if (bitsRemaining < width) {
      _fail('truncated $label');
    }
    var result = 0;
    for (var index = 0; index < width; index += 1) {
      result = result * 2 + (readBit(label) ? 1 : 0);
    }
    return result;
  }

  int readUnsignedExpGolomb(String label, [int maximum = 0xffffffff]) {
    var leadingZeroBits = 0;
    while (!readBit(label)) {
      leadingZeroBits += 1;
      if (leadingZeroBits > 31) {
        _fail('$label Exp-Golomb value is too large');
      }
    }

    final suffix = readBits(leadingZeroBits, label);
    final value = (1 << leadingZeroBits) - 1 + suffix;
    if (value > maxSafeInteger || value > maximum) {
      _fail('$label exceeds $maximum');
    }
    return value;
  }

  int readSignedExpGolomb(
    String label, [
    int minimum = -0x7fffffff,
    int maximum = 0x7fffffff,
  ]) {
    final codeNumber = readUnsignedExpGolomb(label);
    final magnitude = (codeNumber + 1) ~/ 2;
    final value = codeNumber % 2 == 0 ? -magnitude : magnitude;
    if (value < minimum || value > maximum) {
      _fail('$label lies outside the supported range');
    }
    return value;
  }

  /// True when syntax data remains before the mandatory RBSP stop bit.
  bool moreRbspData() {
    if (bitsRemaining == 0) {
      return false;
    }
    final first = _peekBit(_bitOffset);
    if (!first) {
      return true;
    }
    for (var bit = _bitOffset + 1; bit < _bytes.length * 8; bit += 1) {
      if (_peekBit(bit)) {
        return true;
      }
    }
    return false;
  }

  void readTrailingBits() {
    if (!readBit('rbsp_stop_one_bit')) {
      _fail('rbsp_stop_one_bit must be one');
    }
    while (bitsRemaining > 0) {
      if (readBit('rbsp_alignment_zero_bit')) {
        _fail('RBSP alignment bits must be zero');
      }
    }
  }

  bool _peekBit(int bitOffset) {
    final byteIndex = bitOffset ~/ 8;
    if (byteIndex >= _bytes.length) {
      return false;
    }
    return ((_bytes[byteIndex] >> (7 - (bitOffset % 8))) & 1) == 1;
  }

  Never _fail(String message) {
    avcInvalid(_path, message, _absoluteOffset + (_bitOffset ~/ 8));
  }
}
