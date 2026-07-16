/// Top-level restricted PNG decode entry points.
///
/// Dart port of `packages/format/src/png/decode.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart';
import '../errors.dart';
import 'crc32.dart' show adler32;
import 'deflate.dart';
import 'profile.dart';
import 'unfilter.dart';

class PngRgbaDecodeResult {
  const PngRgbaDecodeResult({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;

  /// Fresh caller-owned straight RGBA bytes.
  final Uint8List rgba;
}

/// Decode through the bounded platform-free RFC 1950/1951 implementation.
PngRgbaDecodeResult decodePngRgba(PngDecodePlan plan) {
  try {
    final zlib = readOwnedPngZlib(plan);
    final deflateEnd = checkedAdd(
      plan.deflateRange.offset,
      plan.deflateRange.length,
      zlib.length,
      'PNG DEFLATE range end',
    );
    final filtered = inflateDeflate(
      DeflateInflateInput(
        deflate: Uint8List.sublistView(
          zlib,
          plan.deflateRange.offset,
          deflateEnd,
        ),
        expectedOutputLength: plan.expectedFilteredBytes,
      ),
    );
    return decodePngRgbaFromInflated(plan, filtered);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.pngDeflateInvalid, 'PNG could not be decoded');
  }
}

/// Validate already-inflated bytes before the later native adapter may use
/// them.
PngRgbaDecodeResult decodePngRgbaFromInflated(
  PngDecodePlan plan,
  Uint8List filtered,
) {
  try {
    // Also authenticates the plan brand without retaining or cloning its
    // bytes.
    readOwnedPngZlib(plan);
    if (filtered.length != plan.expectedFilteredBytes) {
      _fail('inflated PNG length does not match the decode plan');
    }
    if (adler32(filtered) != plan.declaredAdler32) {
      _fail('inflated PNG Adler-32 does not match the zlib trailer');
    }
    final rgba = unfilterPngRgba(
      PngUnfilterInput(filtered: filtered, layout: readOwnedPngLayout(plan)),
    );
    if (rgba.length != plan.expectedRgbaBytes) {
      _fail('decoded RGBA length does not match the decode plan');
    }
    return PngRgbaDecodeResult(
      width: plan.width,
      height: plan.height,
      rgba: rgba,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.pngDeflateInvalid,
      'inflated PNG bytes could not be validated',
    );
  }
}

Never _fail(String message) {
  throw FormatError(FormatErrorCode.pngDeflateInvalid, message);
}
