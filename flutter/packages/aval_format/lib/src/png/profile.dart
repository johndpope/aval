/// Restricted PNG profile validation, producing an immutable, caller-opaque
/// decode plan.
///
/// Dart port of `packages/format/src/png/profile.ts`. The TS source keeps
/// the detached zlib bytes and the checked layout out of the public
/// `PngDecodePlan` object shape via module-level `WeakMap`s, so a caller
/// cannot see or tamper with them while `decode.ts` (a trusted sibling
/// module) can still retrieve them by object identity. Dart's library-level
/// privacy gives the same guarantee directly: [PngDecodePlan] stores them in
/// private (`_`-prefixed) fields that only this file can read, and the
/// package-private accessors [readOwnedPngZlib]/[readOwnedPngLayout] below
/// (exported, but only meaningful to sibling `png/*.dart` files) hand them to
/// `decode.dart` without exposing them as public fields on the plan itself.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../errors.dart';
import '../model.dart' show ByteRange, FormatOptions;
import 'chunks.dart';
import 'unfilter.dart';
import 'zlib_envelope.dart';

const int _uint32Max = 0xffffffff;

class PngProfileValidationInput {
  const PngProfileValidationInput({
    required this.png,
    required this.expectedWidth,
    required this.expectedHeight,
    this.options,
  });

  final Uint8List png;
  final int expectedWidth;
  final int expectedHeight;
  final FormatOptions? options;
}

class PngDecodePlan {
  PngDecodePlan._({
    required this.width,
    required this.height,
    required this.byteRange,
    required this.expectedFilteredBytes,
    required this.expectedRgbaBytes,
    required this.zlibByteLength,
    required this.deflateRange,
    required this.declaredAdler32,
    required Uint8List zlibBytes,
    required PngRgbaLayout layout,
  })  : _zlibBytes = zlibBytes,
        _layout = layout;

  final int width;
  final int height;
  final ByteRange byteRange;
  final int expectedFilteredBytes;
  final int expectedRgbaBytes;
  final int zlibByteLength;
  final ByteRange deflateRange;
  final int declaredAdler32;
  final Uint8List _zlibBytes;
  final PngRgbaLayout _layout;

  /// Fresh caller-owned copy of the detached zlib member.
  Uint8List copyZlibBytes() => _copyOwnedPngZlib(this);
}

PngDecodePlan validatePngProfile(PngProfileValidationInput input) {
  try {
    final expectedWidth = _expectedDimension(
      input.expectedWidth,
      'expected PNG width',
    );
    final expectedHeight = _expectedDimension(
      input.expectedHeight,
      'expected PNG height',
    );
    final budgets = resolveFormatBudgets(input.options);
    final chunks = parseRestrictedPngChunks(
      png: input.png,
      expectedWidth: expectedWidth,
      expectedHeight: expectedHeight,
      maximumPngBytes: budgets.maxPngBytes,
    );
    final layout = derivePngRgbaLayout(expectedWidth, expectedHeight);
    final zlib = validateZlibEnvelope(chunks.zlibBytes);
    return PngDecodePlan._(
      width: chunks.width,
      height: chunks.height,
      byteRange: ByteRange(offset: 0, length: input.png.length),
      expectedFilteredBytes: layout.filteredBytes,
      expectedRgbaBytes: layout.rgbaBytes,
      zlibByteLength: chunks.zlibBytes.length,
      deflateRange: zlib.deflateRange,
      declaredAdler32: zlib.declaredAdler32,
      zlibBytes: chunks.zlibBytes,
      layout: layout,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.pngEnvelopeInvalid,
      'PNG profile could not be validated',
    );
  }
}

/// Package-internal zero-copy access to the detached zlib member.
Uint8List readOwnedPngZlib(PngDecodePlan plan) => plan._zlibBytes;

Uint8List _copyOwnedPngZlib(PngDecodePlan plan) {
  final bytes = plan._zlibBytes;
  try {
    return Uint8List.fromList(bytes);
  } catch (_) {
    throw FormatError(
      FormatErrorCode.pngEnvelopeInvalid,
      'PNG zlib copy allocation failed for ${bytes.length} bytes',
    );
  }
}

/// Package-internal access to the checked layout associated with a plan.
PngRgbaLayout readOwnedPngLayout(PngDecodePlan plan) => plan._layout;

int _expectedDimension(int value, String label) {
  if (value < 1 || value > _uint32Max) {
    throw FormatError(
      FormatErrorCode.pngEnvelopeInvalid,
      '$label must be from 1 through $_uint32Max',
    );
  }
  return value;
}
