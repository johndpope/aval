/// AVC (H.264 Constrained Baseline) Annex B subsystem public surface.
///
/// Dart port of `packages/format/src/avc/index.ts`. Mirrors its export list
/// exactly.
library;

export 'inspector.dart'
    show
        inspectAvcAnnexBEncoderCandidateRendition,
        inspectAvcAnnexBRendition;
export 'canonicalize.dart' show canonicalizeAvcConstraintSet2;
export 'codec.dart'
    show
        avcCodecForLevel,
        avcLevelLimits,
        isAvcCodec,
        isAvcLevelIdc,
        parseAvcCodec,
        AvcCodecV01,
        AvcLevelIdc,
        AvcLevelLimits;
export 'incremental_inspector.dart' show AvcIncrementalInspector;
export 'decoder_surface.dart'
    show
        AVC_DECODER_SURFACE_PADDING,
        maximumAvcDecodedRgbaBytes,
        maximumAvcDecoderSurfaceDimension;
export 'encoder_preparation.dart' show prepareAvcEncoderRendition;
export 'rendition_geometry.dart'
    show
        avcQuantizationPolicyForRendition,
        deriveAvcRenditionGeometry,
        deriveAvcRenditionGeometryFromVisible,
        AvcRenditionGeometry,
        AvcRenditionGeometryInput,
        AvcVisibleRenditionGeometryInput;
export 'types.dart'
    show
        AvcAccessUnitInput,
        AvcAccessUnitSummary,
        AvcColorSummary,
        AvcConstrainedBaselineProfile,
        AvcCropSummary,
        AvcEncoderRenditionPreparation,
        AvcEncoderRenditionPreparationInput,
        AvcEncoderUnitStreamInput,
        AvcFrameRate,
        AvcIncrementalAccessUnitInput,
        AvcIncrementalAccessUnitInspection,
        AvcParameterSetSummary,
        AvcQuantizationPolicy,
        AvcRenditionInspection,
        AvcRenditionInspectionInput,
        AvcUnitInput,
        AvcUnitInspection;
export '../model.dart' show AvcProductionRenditionProfileV01;
