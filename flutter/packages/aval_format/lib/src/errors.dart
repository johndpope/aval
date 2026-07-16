/// Stable rejection codes and the immutable error type surfaced by the
/// format package. Dart port of `packages/format/src/errors.ts`.
library;

enum FormatErrorCode {
  inputInvalid('INPUT_INVALID'),
  budgetExceeded('BUDGET_EXCEEDED'),
  integerUnsafe('INTEGER_UNSAFE'),
  headerInvalid('HEADER_INVALID'),
  versionUnsupported('VERSION_UNSUPPORTED'),
  featureUnsupported('FEATURE_UNSUPPORTED'),
  jsonInvalid('JSON_INVALID'),
  jsonDuplicateKey('JSON_DUPLICATE_KEY'),
  jsonDangerousKey('JSON_DANGEROUS_KEY'),
  jsonNoncanonical('JSON_NONCANONICAL'),
  manifestInvalid('MANIFEST_INVALID'),
  graphInvalid('GRAPH_INVALID'),
  indexInvalid('INDEX_INVALID'),
  layoutInvalid('LAYOUT_INVALID'),
  profileInvalid('PROFILE_INVALID'),
  referenceFrameInvalid('REFERENCE_FRAME_INVALID'),
  pngEnvelopeInvalid('PNG_ENVELOPE_INVALID'),
  pngDeflateInvalid('PNG_DEFLATE_INVALID'),
  pngScanlineInvalid('PNG_SCANLINE_INVALID'),
  writerInvalid('WRITER_INVALID'),
  writerNonconvergent('WRITER_NONCONVERGENT');

  const FormatErrorCode(this.wireName);

  /// The exact TypeScript string literal for this code, e.g. `"INPUT_INVALID"`.
  final String wireName;

  @override
  String toString() => wireName;
}

/// Optional structured details attached to a [FormatError].
class FormatErrorDetails {
  const FormatErrorDetails({this.path, this.offset});

  final String? path;
  final int? offset;
}

/// A stable, immutable rejection surfaced by the format package.
///
/// Mirrors the TypeScript `FormatError` class: `code` is always present,
/// `path` and `offset` are present only when supplied.
class FormatError implements Exception {
  FormatError(this.code, this.message, [FormatErrorDetails? details])
      : path = details?.path,
        offset = details?.offset;

  final FormatErrorCode code;
  final String message;
  final String? path;
  final int? offset;

  /// Matches the TS `Error.name` override, kept for parity/debug output.
  String get name => 'FormatError';

  @override
  String toString() => 'FormatError: $message';
}

bool isFormatError(Object? error) => error is FormatError;
