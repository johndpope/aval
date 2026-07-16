/// RFC 1950 zlib envelope (CMF/FLG header, dictionary flag, and Adler-32
/// trailer) validation for the restricted PNG profile.
///
/// Dart port of `packages/format/src/png/zlib-envelope.ts`.
library;

import 'dart:typed_data';

import '../errors.dart';
import '../model.dart' show ByteRange;

class ZlibEnvelope {
  const ZlibEnvelope({
    required this.deflateRange,
    required this.declaredAdler32,
  });

  final ByteRange deflateRange;
  final int declaredAdler32;
}

ZlibEnvelope validateZlibEnvelope(Uint8List zlib) {
  if (zlib.length < 7) {
    _fail('zlib member is missing DEFLATE data or Adler-32 trailer');
  }
  final cmf = zlib[0];
  final flg = zlib[1];
  if ((cmf & 0x0f) != 8) _fail('zlib compression method must be DEFLATE', 0);
  if ((cmf >> 4) > 7) _fail('zlib window size exceeds 32 KiB', 0);
  if (((cmf << 8) | flg) % 31 != 0) _fail('zlib FCHECK is invalid', 1);
  if ((flg & 0x20) != 0) _fail('zlib preset dictionaries are forbidden', 1);
  final deflateLength = zlib.length - 6;
  if (deflateLength < 1) _fail('zlib member must contain a DEFLATE block', 2);
  final trailerOffset = zlib.length - 4;
  final declaredAdler32 = _readUint32Be(zlib, trailerOffset);
  return ZlibEnvelope(
    deflateRange: ByteRange(offset: 2, length: deflateLength),
    declaredAdler32: declaredAdler32,
  );
}

int _readUint32Be(Uint8List bytes, int offset) {
  return bytes[offset] * 0x1000000 +
      bytes[offset + 1] * 0x10000 +
      bytes[offset + 2] * 0x100 +
      bytes[offset + 3];
}

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.pngEnvelopeInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}
