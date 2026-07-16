/// Canonical Huffman tree construction and decoding for RFC 1951 DEFLATE.
///
/// Dart port of `packages/format/src/png/deflate-huffman.ts`. The TS
/// `Array.isArray`/`instanceof Uint8Array` runtime check on `lengths` is
/// dropped because Dart's `List<int>` parameter type enforces it at compile
/// time.
library;

import 'dart:typed_data';

import 'deflate_bit_reader.dart';

const int _maxCodeBits = 15;

class DeflateHuffmanTable {
  DeflateHuffmanTable._(this._codes, this._maximumBits);

  final List<Map<int, int>> _codes;
  final int _maximumBits;

  static DeflateHuffmanTable build(List<int> lengths, String label) {
    final counts = Uint16List(_maxCodeBits + 1);
    var symbols = 0;
    var maximumBits = 0;
    for (var symbol = 0; symbol < lengths.length; symbol += 1) {
      final length = lengths[symbol];
      if (length < 0 || length > _maxCodeBits) {
        deflateInvalid('$label contains an invalid code length');
      }
      if (length != 0) {
        counts[length] = counts[length] + 1;
        symbols += 1;
        if (length > maximumBits) maximumBits = length;
      }
    }
    if (symbols == 0) deflateInvalid('$label Huffman tree is empty');

    var remaining = 1;
    for (var bits = 1; bits <= _maxCodeBits; bits += 1) {
      remaining = remaining * 2 - counts[bits];
      if (remaining < 0) {
        deflateInvalid('$label Huffman tree is oversubscribed');
      }
    }
    final permittedSingle = symbols == 1 && counts[1] == 1;
    if (remaining != 0 && !permittedSingle) {
      deflateInvalid('$label Huffman tree is incomplete');
    }

    final nextCodes = Uint16List(_maxCodeBits + 1);
    var code = 0;
    for (var bits = 1; bits <= _maxCodeBits; bits += 1) {
      code = (code + counts[bits - 1]) << 1;
      nextCodes[bits] = code;
    }
    final mutable = List<Map<int, int>>.generate(
      maximumBits + 1,
      (_) => <int, int>{},
    );
    for (var symbol = 0; symbol < lengths.length; symbol += 1) {
      final length = lengths[symbol];
      if (length == 0) continue;
      final canonical = nextCodes[length];
      nextCodes[length] = canonical + 1;
      mutable[length][_reverseBits(canonical, length)] = symbol;
    }
    return DeflateHuffmanTable._(mutable, maximumBits);
  }

  int decode(DeflateBitReader reader, String label) {
    var code = 0;
    for (var length = 1; length <= _maximumBits; length += 1) {
      code |= reader.readBits(1, label) << (length - 1);
      final symbol = _codes[length][code];
      if (symbol != null) {
        reader.decodedSymbol();
        return symbol;
      }
    }
    deflateInvalid('$label does not match the Huffman tree');
  }
}

int _reverseBits(int value, int width) {
  var result = 0;
  for (var index = 0; index < width; index += 1) {
    result = (result << 1) | ((value >> index) & 1);
  }
  return result;
}
