/// Canonical parser, validator, and types for AVAL binary assets.
///
/// Pure Dart port of `@pixel-point/aval-format`, mirroring
/// `packages/format/src/index.ts`.
library;

export 'src/constants.dart'
    show
        chunkIndexHeaderLength,
        chunkIndexMagic,
        chunkIndexRecordLength,
        formatAlignment,
        formatDefaultBudgets,
        formatHeaderLength,
        formatMagic,
        formatVersionMajor,
        formatVersionMinor,
        identifierPattern,
        sha256HexPattern,
        resolveFormatBudgets;
export 'src/errors.dart'
    show FormatError, FormatErrorCode, FormatErrorDetails, isFormatError;
export 'src/canonical_json.dart'
    show
        parseStrictJson,
        serializeCanonicalJson,
        serializeCanonicalJsonWithLimits,
        CanonicalJsonWriteLimits,
        compareUtf8Strings;
export 'src/h264/index.dart';
export 'src/graph_adapter.dart' show adaptManifestToMotionGraph;
export 'src/header.dart' show parseHeader;
export 'src/chunk_plan.dart'
    show
        createCanonicalChunkPlan,
        validateCanonicalChunkSpans,
        CanonicalChunkPlan,
        CanonicalChunkSlot,
        CanonicalChunkSpan;
export 'src/video/codec_string.dart'
    show
        isVideoCodecString,
        parseVideoCodecString,
        videoBitstreamByCodec,
        videoCodecs,
        ParsedVideoCodecString;
export 'src/video/geometry.dart'
    show deriveVideoRenditionGeometry, packedAlphaGutter;
export 'src/compile_bundle_report.dart';
export 'src/video/model.dart'
    show VideoRenditionGeometry, VideoRenditionGeometryInput, VideoStoragePolicy;
export 'src/h265/index.dart';
export 'src/vp9/index.dart';
export 'src/av1/index.dart';
export 'src/png/crc32.dart' show adler32, crc32;
export 'src/png/decode.dart'
    show decodePngRgba, decodePngRgbaFromInflated, PngRgbaDecodeResult;
export 'src/png/profile.dart'
    show validatePngProfile, PngDecodePlan, PngProfileValidationInput;
export 'src/model.dart';
export 'src/parser.dart' show parseFrontIndex, validateCompleteAsset;
export 'src/writer.dart' show writeCanonicalAsset;
