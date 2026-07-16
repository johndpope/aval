import type { H265ProfileTierLevel } from "./parameter-sets.js";

export interface H265AccessUnitInput {
  readonly bytes: Uint8Array;
  readonly key: boolean;
}

export interface H265UnitInput {
  readonly id: string;
  readonly accessUnits: readonly H265AccessUnitInput[];
}

export interface H265FrameRate {
  readonly numerator: number;
  readonly denominator: number;
}

export interface H265MainProfile {
  readonly codedWidth: number;
  readonly codedHeight: number;
  readonly expectedVisibleRect?: readonly [
    x: 0,
    y: 0,
    width: number,
    height: number
  ];
  readonly frameRate: H265FrameRate;
  readonly requireBt709LimitedRange: true;
}

export interface H265RenditionInspectionInput {
  readonly profile: H265MainProfile;
  readonly units: readonly H265UnitInput[];
}

export interface H265ColorSummary {
  readonly fullRange: boolean;
  readonly colourPrimaries?: number;
  readonly transferCharacteristics?: number;
  readonly matrixCoefficients?: number;
}

export interface H265CropSummary {
  readonly left: number;
  readonly right: number;
  readonly top: number;
  readonly bottom: number;
  readonly visibleWidth: number;
  readonly visibleHeight: number;
}

export interface H265ParameterSetSummary {
  readonly profileTierLevel: H265ProfileTierLevel;
  readonly codec: string;
  readonly codedWidth: number;
  readonly codedHeight: number;
  readonly crop: H265CropSummary;
  readonly bitDepth: 8;
  readonly chromaFormat: "4:2:0";
  readonly maxNumReorderPics: number;
  readonly maxDecPicBuffering: number;
  readonly color: H265ColorSummary;
}

export type H265RandomAccessKind = "bla" | "idr" | "cra";

export interface H265AccessUnitSummary {
  readonly decodeIndex: number;
  readonly presentationIndex: number;
  readonly pictureOrderCount: number;
  readonly key: boolean;
  readonly randomAccess: H265RandomAccessKind | undefined;
  readonly sliceType: "I" | "P" | "B";
  readonly temporalId: number;
  readonly referencedPictureOrderCounts: readonly number[];
  readonly nalUnitTypes: readonly number[];
}

export interface H265UnitInspection {
  readonly id: string;
  readonly accessUnits: readonly H265AccessUnitSummary[];
  readonly decodeToPresentation: readonly number[];
}

export interface H265RenditionInspection {
  readonly parameterSet: H265ParameterSetSummary;
  readonly decoderConfig: H265VideoDecoderConfig;
  readonly units: readonly H265UnitInspection[];
}

/** Structural subset of VideoDecoderConfig used by the browser adapter. */
export interface H265VideoDecoderConfig {
  readonly codec: string;
  readonly codedWidth: number;
  readonly codedHeight: number;
  readonly displayAspectWidth: number;
  readonly displayAspectHeight: number;
  readonly colorSpace: {
    readonly primaries: "bt709";
    readonly transfer: "bt709";
    readonly matrix: "bt709";
    readonly fullRange: false;
  };
}
