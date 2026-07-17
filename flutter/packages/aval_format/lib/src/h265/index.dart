/// HEVC (H.265) Annex-B subsystem public surface.
///
/// Dart port of `packages/format/src/h265/index.ts`. Mirrors its export list
/// exactly.
library;

export 'annex_b.dart'
    show
        H265_MAX_ACCESS_UNIT_BYTES,
        H265_MAX_NAL_UNITS,
        H265_NAL_AUD,
        H265_NAL_BLA_N_LP,
        H265_NAL_BLA_W_LP,
        H265_NAL_BLA_W_RADL,
        H265_NAL_CRA_NUT,
        H265_NAL_IDR_N_LP,
        H265_NAL_IDR_W_RADL,
        H265_NAL_PPS,
        H265_NAL_PREFIX_SEI,
        H265_NAL_SPS,
        H265_NAL_SUFFIX_SEI,
        H265_NAL_VPS,
        isH265IdrNalType,
        isH265RandomAccessNalType,
        isH265VclNalType,
        removeH265EmulationPrevention,
        splitH265AnnexBAccessUnit,
        H265AnnexBNalUnit,
        H265AnnexBOptions;
export 'canonicalize.dart'
    show canonicalizeH265AccessUnit, canonicalizeH265EncoderUnitStream;
export 'bit_reader.dart' show H265RbspBitReader;
export 'codec.dart' show createH265VideoDecoderConfig, h265CodecString;
export 'inspector.dart' show inspectH265AnnexBRendition;
export 'parameter_sets.dart'
    show
        parseH265Pps,
        parseH265ShortTermReferencePictureSet,
        parseH265Sps,
        parseH265Vps,
        sameH265ProfileTierLevel,
        H265ProfileTierLevel,
        H265ShortTermReferencePicture,
        H265ShortTermReferencePictureSet,
        ParsedH265Pps,
        ParsedH265Sps,
        ParsedH265Vps;
export 'presentation_order.dart'
    show
        createH265PictureOrderState,
        deriveH265PictureOrderCount,
        deriveH265PresentationOrder,
        H265DecodedPictureOrder,
        H265PictureOrderState;
export 'slice_header.dart' show parseH265SliceHeader, ParsedH265SliceHeader;
export 'types.dart'
    show
        H265AccessUnitInput,
        H265AccessUnitSummary,
        H265ColorSummary,
        H265CropSummary,
        H265FrameRate,
        H265MainProfile,
        H265ParameterSetSummary,
        H265RandomAccessKind,
        H265RenditionInspection,
        H265RenditionInspectionInput,
        H265UnitInput,
        H265UnitInspection,
        H265VideoDecoderConfig;
