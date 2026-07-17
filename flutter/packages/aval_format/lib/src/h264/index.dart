/// H.264 (High-profile) Annex B subsystem public surface.
///
/// Dart port of `packages/format/src/h264/index.ts`. Mirrors its export list
/// exactly.
library;

export 'inspector.dart' show inspectH264AnnexBRendition;
export 'codec.dart'
    show
        h264CodecForLevel,
        h264LevelLimits,
        isH264Codec,
        isH264LevelIdc,
        parseH264Codec,
        H264Codec,
        H264LevelIdc,
        H264LevelLimits;
export 'decoder_surface.dart'
    show
        h264DecoderSurfacePadding,
        maximumH264DecodedRgbaBytes,
        maximumH264DecoderSurfaceDimension;
export 'encoder_preparation.dart' show prepareH264EncoderRendition;
export 'types.dart'
    show
        H264AccessUnitInput,
        H264AccessUnitSummary,
        H264ColorSummary,
        H264Profile,
        H264CropSummary,
        H264EncoderRenditionPreparation,
        H264EncoderRenditionPreparationInput,
        H264EncoderUnitStreamInput,
        H264FrameRate,
        H264ParameterSetSummary,
        H264RenditionInspection,
        H264RenditionInspectionInput,
        H264UnitInput,
        H264UnitInspection;
