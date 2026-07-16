/// Unsigned CRC-32 (PNG/IEEE) and Adler-32 (RFC 1950) checksums used by the
/// restricted PNG profile.
///
/// Dart port of `packages/format/src/png/crc32.ts`. The TS source guards both
/// functions with a runtime `instanceof Uint8Array` check because JavaScript
/// has no static types; Dart's `Uint8List` parameter type enforces this at
/// compile time instead, so that check is not reproduced here.
library;

import 'dart:typed_data';

final Uint32List _crcTable = _buildCrcTable();
const int _adlerModulus = 65521;

/// Unsigned PNG/IEEE CRC-32 over one bounded byte view.
int crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (var index = 0; index < bytes.length; index += 1) {
    crc = (crc >>> 8) ^ _crcTable[(crc ^ bytes[index]) & 0xff];
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Unsigned RFC 1950 Adler-32 over one bounded byte view.
int adler32(Uint8List bytes) {
  var a = 1;
  var b = 0;
  for (var offset = 0; offset < bytes.length; offset += 5552) {
    final end = bytes.length < offset + 5552 ? bytes.length : offset + 5552;
    for (var index = offset; index < end; index += 1) {
      a += bytes[index];
      b += a;
    }
    a %= _adlerModulus;
    b %= _adlerModulus;
  }
  return ((b << 16) | a) & 0xffffffff;
}

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var index = 0; index < table.length; index += 1) {
    var value = index;
    for (var bit = 0; bit < 8; bit += 1) {
      value = (value & 1) == 0 ? value >>> 1 : 0xedb88320 ^ (value >>> 1);
    }
    table[index] = value & 0xffffffff;
  }
  return table;
}
