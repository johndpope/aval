/// Canonical parser, validator, and types for AVAL binary assets.
///
/// Pure Dart port of `@pixel-point/aval-format`, mirroring
/// `packages/format/src/index.ts`.
library;

export 'src/constants.dart'
    show
        accessUnitIndexHeaderLength,
        accessUnitIndexMagic,
        accessUnitRecordLength,
        formatAlignment,
        formatDefaultBudgets,
        formatHeaderLength,
        formatMagic,
        formatVersionMajor,
        formatVersionMinor,
        identifierPattern,
        referenceFrameHeaderLength,
        referenceFrameMagic,
        sha256HexPattern,
        resolveFormatBudgets;
export 'src/errors.dart' show FormatError, FormatErrorCode, FormatErrorDetails, isFormatError;
export 'src/canonical_json.dart'
    show
        parseStrictJson,
        serializeCanonicalJson,
        serializeCanonicalJsonWithLimits,
        CanonicalJsonWriteLimits,
        compareUtf8Strings;
export 'src/avc/index.dart';
export 'src/graph_adapter.dart' show adaptManifestToMotionGraph;
export 'src/header.dart' show parseHeader;
export 'src/png/crc32.dart' show adler32, crc32;
export 'src/png/decode.dart' show decodePngRgba, decodePngRgbaFromInflated, PngRgbaDecodeResult;
export 'src/png/profile.dart' show validatePngProfile, PngDecodePlan, PngProfileValidationInput;
export 'src/model.dart';
export 'src/parser.dart' show parseFrontIndex, validateCompleteAsset;
export 'src/reference_frame.dart'
    show
        encodeReferenceFrame,
        parseReferenceFrameHeader,
        validateReferenceFrame,
        ReferenceFrameInput,
        ReferenceFrameValidationInput;
export 'src/writer.dart' show writeCanonicalAsset;
