import {
  IDENTIFIER_PATTERN,
  PACKED_ALPHA_GUTTER,
  h264CodecForLevel,
  inspectAv1Rendition,
  inspectH264AnnexBRendition,
  inspectH265AnnexBRendition,
  inspectVp9Rendition,
  parseVideoCodecString,
  type CompiledManifest,
  type EncodedChunkRecord,
  type ProductionRendition,
  type Rect,
  type VideoBitDepth,
  type VideoBitstream,
  type VideoCodec
} from "@pixel-point/aval-format";

export const VIDEO_CODEC_FAMILIES = Object.freeze([
  "h264",
  "h265",
  "vp9",
  "av1"
] as const);

export type VideoCodecFamily = (typeof VIDEO_CODEC_FAMILIES)[number];

export type VideoCodecAdapterManifest = Pick<
  CompiledManifest,
  "codec" | "bitstream" | "layout" | "canvas" | "frameRate"
>;

export interface BorrowedVideoChunkPlan {
  readonly blobKey: string;
  readonly relativeOffset: number;
  readonly byteLength: number;
  readonly record: Readonly<EncodedChunkRecord>;
}

export interface BorrowedVideoUnitPlan {
  readonly id: string;
  readonly expectedDisplayedFrames: number;
  /** Encoded chunks in decoder submission order. */
  readonly chunks: readonly Readonly<BorrowedVideoChunkPlan>[];
}

export interface BorrowedVideoRenditionPlan {
  readonly manifest: Readonly<VideoCodecAdapterManifest>;
  readonly rendition: Readonly<ProductionRendition>;
  readonly units: readonly Readonly<BorrowedVideoUnitPlan>[];
}

export type BorrowVerifiedVideoRange = (
  blobKey: string,
  relativeOffset: number,
  byteLength: number
) => Uint8Array;

export interface VideoDecodeSubmissionMetadata {
  readonly decodeIndex: number;
  readonly chunkType: EncodedVideoChunkType;
  readonly presentationTimestamp: number;
  /** Per-displayed-frame timestamp step from the encoded chunk index. */
  readonly duration: number;
  readonly displayedFrameCount: number;
  /** Unit-local presentation indices, in coded-frame order within this chunk. */
  readonly presentationIndices: readonly number[];
}

export interface VideoCodecUnitInspection {
  readonly id: string;
  readonly displayedFrameCount: number;
  /** Normalized metadata in decoder submission order. */
  readonly submissions: readonly Readonly<VideoDecodeSubmissionMetadata>[];
}

export interface VideoCodecAdapterInspection {
  readonly family: VideoCodecFamily;
  readonly bitstream: VideoBitstream;
  readonly bitDepth: VideoBitDepth;
  readonly decoderConfig: Readonly<VideoDecoderConfig>;
  readonly units: readonly Readonly<VideoCodecUnitInspection>[];
}

interface DecodedStorageGeometry {
  readonly width: number;
  readonly height: number;
  readonly rect: readonly [x: 0, y: 0, width: number, height: number];
}

interface ValidatedChunkPlan {
  readonly blobKey: string;
  readonly relativeOffset: number;
  readonly byteLength: number;
  readonly record: Readonly<EncodedChunkRecord>;
}

interface ValidatedUnitPlan {
  readonly id: string;
  readonly expectedDisplayedFrames: number;
  readonly chunks: readonly ValidatedChunkPlan[];
}

interface BorrowedChunk extends ValidatedChunkPlan {
  readonly bytes: Uint8Array;
}

interface BorrowedUnit {
  readonly id: string;
  readonly expectedDisplayedFrames: number;
  readonly chunks: readonly BorrowedChunk[];
}

interface SyntaxChunkInspection {
  readonly chunkType: EncodedVideoChunkType;
  readonly displayedFrameCount: number;
  readonly expectedPresentationIndex?: number;
}

interface SyntaxUnitInspection {
  readonly id: string;
  readonly chunks: readonly SyntaxChunkInspection[];
}

const EXPECTED_BITSTREAM = Object.freeze({
  h264: "annex-b",
  h265: "annex-b",
  vp9: "frame",
  av1: "low-overhead"
} as const satisfies Readonly<Record<VideoCodecFamily, VideoBitstream>>);

const BT709_LIMITED_COLOR_SPACE = Object.freeze({
  primaries: "bt709" as const,
  transfer: "bt709" as const,
  matrix: "bt709" as const,
  fullRange: false as const
});

/**
 * Synchronously certifies borrowed verified chunks and returns no byte views.
 * The borrowing authority and every borrowed view remain confined to this call.
 */
export function inspectBorrowedVideoRendition(
  plan: Readonly<BorrowedVideoRenditionPlan>,
  borrow: BorrowVerifiedVideoRange
): Readonly<VideoCodecAdapterInspection> {
  if (plan === null || typeof plan !== "object" || Array.isArray(plan)) {
    invalid("rendition plan must be an object");
  }
  if (typeof borrow !== "function") {
    invalid("verified byte borrowing authority is unavailable");
  }

  const family = validateManifestAndRendition(plan.manifest, plan.rendition);
  const geometry = validateDecodedStorageGeometry(plan.manifest, plan.rendition);
  const units = validateUnits(plan.units);
  const borrowedUnits = borrowUnits(units, borrow);

  let codec: string;
  let inspectedBitDepth: VideoBitDepth;
  let syntaxUnits: readonly SyntaxUnitInspection[];
  switch (family) {
    case "h264": {
      const inspection = inspectH264AnnexBRendition(Object.freeze({
        profile: Object.freeze({
          codedWidth: plan.rendition.codedWidth,
          codedHeight: plan.rendition.codedHeight,
          expectedVisibleRect: geometry.rect,
          frameRate: freezeFrameRate(plan.manifest.frameRate),
          requireBt709LimitedRange: true as const
        }),
        units: Object.freeze(borrowedUnits.map((unit) => Object.freeze({
          id: unit.id,
          accessUnits: Object.freeze(unit.chunks.map((chunk) => Object.freeze({
            bytes: chunk.bytes,
            key: chunk.record.randomAccess
          })))
        })))
      }));
      requireBt709Limited(inspection.parameterSet.color, "H.264 SPS");
      requireGeometry(
        inspection.parameterSet.codedWidth,
        inspection.parameterSet.codedHeight,
        plan.rendition,
        "H.264 SPS"
      );
      requireVisibleGeometry(
        inspection.parameterSet.crop.visibleWidth,
        inspection.parameterSet.crop.visibleHeight,
        geometry,
        "H.264 SPS"
      );
      codec = h264CodecForLevel(inspection.parameterSet.levelIdc);
      inspectedBitDepth = 8;
      syntaxUnits = Object.freeze(inspection.units.map((unit) => Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.accessUnits.map((accessUnit) => Object.freeze({
          chunkType: accessUnit.key ? "key" as const : "delta" as const,
          displayedFrameCount: 1,
          expectedPresentationIndex: accessUnit.presentationIndex
        })))
      })));
      break;
    }
    case "h265": {
      const inspection = inspectH265AnnexBRendition(Object.freeze({
        profile: Object.freeze({
          codedWidth: plan.rendition.codedWidth,
          codedHeight: plan.rendition.codedHeight,
          expectedVisibleRect: geometry.rect,
          frameRate: freezeFrameRate(plan.manifest.frameRate),
          requireBt709LimitedRange: true as const
        }),
        units: Object.freeze(borrowedUnits.map((unit) => Object.freeze({
          id: unit.id,
          accessUnits: Object.freeze(unit.chunks.map((chunk) => Object.freeze({
            bytes: chunk.bytes,
            key: chunk.record.randomAccess
          })))
        })))
      }));
      requireBt709Limited(inspection.parameterSet.color, "HEVC SPS");
      requireGeometry(
        inspection.parameterSet.codedWidth,
        inspection.parameterSet.codedHeight,
        plan.rendition,
        "HEVC SPS"
      );
      requireVisibleGeometry(
        inspection.parameterSet.crop.visibleWidth,
        inspection.parameterSet.crop.visibleHeight,
        geometry,
        "HEVC SPS"
      );
      codec = inspection.decoderConfig.codec;
      inspectedBitDepth = inspection.parameterSet.bitDepth;
      syntaxUnits = Object.freeze(inspection.units.map((unit) => Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.accessUnits.map((accessUnit) => Object.freeze({
          chunkType: accessUnit.key ? "key" as const : "delta" as const,
          displayedFrameCount: 1,
          expectedPresentationIndex: accessUnit.presentationIndex
        })))
      })));
      break;
    }
    case "vp9": {
      const inspection = inspectVp9Rendition(Object.freeze({
        width: plan.rendition.codedWidth,
        height: plan.rendition.codedHeight,
        frameRate: freezeFrameRate(plan.manifest.frameRate),
        averageBitrate: plan.rendition.bitrate.average,
        units: Object.freeze(borrowedUnits.map((unit) => Object.freeze({
          id: unit.id,
          expectedDisplayedFrames: unit.expectedDisplayedFrames,
          packets: Object.freeze(unit.chunks.map((chunk) => Object.freeze({
            bytes: chunk.bytes,
            key: chunk.record.randomAccess,
            timestamp: chunk.record.presentationTimestamp
          })))
        })))
      }));
      requireGeometry(inspection.width, inspection.height, plan.rendition, "VP9 stream");
      validateVp9KeyGeometry(inspection.units, plan.rendition, geometry);
      codec = inspection.codec;
      inspectedBitDepth = inspection.bitDepth;
      syntaxUnits = Object.freeze(inspection.units.map((unit) => Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.packets.map((packet) => Object.freeze({
          chunkType: packet.chunkType,
          displayedFrameCount: packet.displayedFrameCount
        })))
      })));
      break;
    }
    case "av1": {
      const inspection = inspectAv1Rendition(Object.freeze({
        width: plan.rendition.codedWidth,
        height: plan.rendition.codedHeight,
        bitDepth: plan.rendition.bitDepth,
        units: Object.freeze(borrowedUnits.map((unit) => Object.freeze({
          id: unit.id,
          expectedDisplayedFrames: unit.expectedDisplayedFrames,
          chunks: Object.freeze(unit.chunks.map((chunk) => Object.freeze({
            bytes: chunk.bytes,
            key: chunk.record.randomAccess,
            timestamp: chunk.record.presentationTimestamp
          })))
        })))
      }));
      requireGeometry(
        inspection.sequence.maxWidth,
        inspection.sequence.maxHeight,
        plan.rendition,
        "AV1 sequence header"
      );
      requireBt709Limited(inspection.sequence, "AV1 sequence header");
      codec = inspection.codec;
      inspectedBitDepth = inspection.sequence.bitDepth;
      syntaxUnits = Object.freeze(inspection.units.map((unit) => Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.chunks.map((chunk) => Object.freeze({
          chunkType: chunk.chunkType,
          displayedFrameCount: chunk.displayedFrameCount
        })))
      })));
      break;
    }
    default:
      return exhaustiveFamily(family);
  }

  if (inspectedBitDepth !== plan.rendition.bitDepth) {
    invalid("inspected bit depth disagrees with the manifest rendition");
  }
  if (codec !== plan.rendition.codec) {
    invalid("inspected codec string disagrees with the manifest rendition");
  }

  const normalizedUnits = normalizeSubmissionMetadata(units, syntaxUnits);
  const decoderConfig = createDecoderConfig(codec, plan.rendition, geometry);
  return Object.freeze({
    family,
    bitstream: plan.manifest.bitstream,
    bitDepth: inspectedBitDepth,
    decoderConfig,
    units: normalizedUnits
  });
}

function validateManifestAndRendition(
  manifest: Readonly<VideoCodecAdapterManifest>,
  rendition: Readonly<ProductionRendition>
): VideoCodecFamily {
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    invalid("manifest adapter data must be an object");
  }
  if (!isVideoCodecFamily(manifest.codec)) {
    invalid("manifest codec family is unsupported");
  }
  const family = manifest.codec;
  if (manifest.bitstream !== EXPECTED_BITSTREAM[family]) {
    invalid(`manifest ${family} bitstream must be ${EXPECTED_BITSTREAM[family]}`);
  }
  validateFrameRate(manifest.frameRate);
  if (rendition === null || typeof rendition !== "object" || Array.isArray(rendition)) {
    invalid("manifest rendition must be an object");
  }
  if (typeof rendition.id !== "string" || !IDENTIFIER_PATTERN.test(rendition.id)) {
    invalid("manifest rendition id is invalid");
  }
  const parsedCodec = parseVideoCodecString(rendition.codec);
  if (parsedCodec?.family !== family) {
    invalid("rendition codec string disagrees with the manifest codec family");
  }
  if (rendition.bitDepth !== 8 && rendition.bitDepth !== 10) {
    invalid("manifest rendition bit depth is invalid");
  }
  if (family !== "av1" && rendition.bitDepth !== 8) {
    invalid(`${family} manifest renditions must be 8-bit`);
  }
  requirePositiveEven(rendition.codedWidth, "rendition coded width");
  requirePositiveEven(rendition.codedHeight, "rendition coded height");
  if (
    rendition.bitrate === null ||
    typeof rendition.bitrate !== "object" ||
    !isPositiveSafeInteger(rendition.bitrate.average) ||
    !isPositiveSafeInteger(rendition.bitrate.peak) ||
    rendition.bitrate.average > rendition.bitrate.peak
  ) {
    invalid("manifest rendition bitrate is invalid");
  }
  return family;
}

function validateDecodedStorageGeometry(
  manifest: Readonly<VideoCodecAdapterManifest>,
  rendition: Readonly<ProductionRendition>
): Readonly<DecodedStorageGeometry> {
  if (manifest.layout !== "opaque" && manifest.layout !== "packed-alpha") {
    invalid("manifest video layout is invalid");
  }
  if (
    manifest.canvas === null ||
    typeof manifest.canvas !== "object" ||
    !isPositiveSafeInteger(manifest.canvas.width) ||
    !isPositiveSafeInteger(manifest.canvas.height)
  ) {
    invalid("manifest canvas geometry is invalid");
  }
  const layout = rendition.alphaLayout;
  if (layout === null || typeof layout !== "object") {
    invalid("manifest alpha layout is invalid");
  }
  if (
    (manifest.layout === "opaque" && layout.type !== "opaque") ||
    (manifest.layout === "packed-alpha" && layout.type !== "stacked")
  ) {
    invalid("rendition alpha layout disagrees with the manifest layout");
  }
  const colorRect = validateRect(
    layout.colorRect,
    rendition.codedWidth,
    rendition.codedHeight,
    "color rectangle"
  );
  if (colorRect[0] !== 0 || colorRect[1] !== 0) {
    invalid("visible color rectangle must begin at the decoded origin");
  }
  if (colorRect[2] > manifest.canvas.width || colorRect[3] > manifest.canvas.height) {
    invalid("visible color rectangle does not fit the manifest canvas");
  }
  if (
    BigInt(colorRect[2]) * BigInt(manifest.canvas.height) !==
    BigInt(colorRect[3]) * BigInt(manifest.canvas.width)
  ) {
    invalid("visible color rectangle disagrees with the manifest canvas aspect ratio");
  }

  const paneWidth = alignEven(colorRect[2]);
  const paneHeight = alignEven(colorRect[3]);
  let storageHeight = paneHeight;
  if (layout.type === "stacked") {
    const alphaRect = validateRect(
      layout.alphaRect,
      rendition.codedWidth,
      rendition.codedHeight,
      "alpha rectangle"
    );
    if (
      alphaRect[0] !== 0 ||
      alphaRect[1] !== paneHeight + PACKED_ALPHA_GUTTER ||
      alphaRect[2] !== colorRect[2] ||
      alphaRect[3] !== colorRect[3]
    ) {
      invalid("alpha rectangle disagrees with the packed-alpha geometry");
    }
    storageHeight = 2 * paneHeight + PACKED_ALPHA_GUTTER;
  }
  if (paneWidth > rendition.codedWidth || storageHeight > rendition.codedHeight) {
    invalid("decoded storage geometry exceeds the coded rendition surface");
  }
  const rect = Object.freeze([0, 0, paneWidth, storageHeight]) as readonly [
    x: 0,
    y: 0,
    width: number,
    height: number
  ];
  return Object.freeze({ width: paneWidth, height: storageHeight, rect });
}

function validateUnits(
  value: readonly Readonly<BorrowedVideoUnitPlan>[]
): readonly ValidatedUnitPlan[] {
  requireDenseNonEmptyArray(value, "rendition units");
  const seenIds = new Set<string>();
  const units = value.map((unit, unitIndex) => {
    const path = `units[${String(unitIndex)}]`;
    if (unit === null || typeof unit !== "object" || Array.isArray(unit)) {
      invalid(`${path} must be an object`);
    }
    if (typeof unit.id !== "string" || !IDENTIFIER_PATTERN.test(unit.id)) {
      invalid(`${path} id is invalid`);
    }
    if (seenIds.has(unit.id)) invalid(`${path} id is duplicated`);
    seenIds.add(unit.id);
    if (!isPositiveSafeInteger(unit.expectedDisplayedFrames)) {
      invalid(`${path} displayed frame count is invalid`);
    }
    requireDenseNonEmptyArray(unit.chunks, `${path} chunks`);
    const chunks = unit.chunks.map((chunk, chunkIndex) =>
      validateChunk(chunk, `${path}.chunks[${String(chunkIndex)}]`)
    );
    if (!chunks[0]!.record.randomAccess) {
      invalid(`${path} must begin with a random-access chunk`);
    }
    return Object.freeze({
      id: unit.id,
      expectedDisplayedFrames: unit.expectedDisplayedFrames,
      chunks: Object.freeze(chunks)
    });
  });
  return Object.freeze(units);
}

function validateChunk(
  chunk: Readonly<BorrowedVideoChunkPlan>,
  path: string
): ValidatedChunkPlan {
  if (chunk === null || typeof chunk !== "object" || Array.isArray(chunk)) {
    invalid(`${path} must be an object`);
  }
  if (typeof chunk.blobKey !== "string" || chunk.blobKey.length === 0) {
    invalid(`${path} blob key is invalid`);
  }
  requireNonNegativeSafeInteger(chunk.relativeOffset, `${path} relative offset`);
  if (!isPositiveSafeInteger(chunk.byteLength)) {
    invalid(`${path} byte length is invalid`);
  }
  const record = chunk.record;
  if (record === null || typeof record !== "object" || Array.isArray(record)) {
    invalid(`${path} encoded chunk record is invalid`);
  }
  requireNonNegativeSafeInteger(record.byteOffset, `${path} record byte offset`);
  if (!isPositiveSafeInteger(record.byteLength) || record.byteLength !== chunk.byteLength) {
    invalid(`${path} byte length disagrees with its encoded chunk record`);
  }
  requireNonNegativeSafeInteger(
    record.presentationTimestamp,
    `${path} presentation timestamp`
  );
  requireNonNegativeSafeInteger(record.duration, `${path} duration`);
  requireNonNegativeSafeInteger(
    record.displayedFrameCount,
    `${path} displayed frame count`
  );
  if (typeof record.randomAccess !== "boolean") {
    invalid(`${path} random-access marker is invalid`);
  }
  if (record.displayedFrameCount > 0 && record.duration === 0) {
    invalid(`${path} displayed frames require a positive duration`);
  }
  if (record.displayedFrameCount > 0) {
    checkedPresentationTimestamp(
      record.presentationTimestamp,
      record.duration,
      record.displayedFrameCount - 1,
      path
    );
  }
  return Object.freeze({
    blobKey: chunk.blobKey,
    relativeOffset: chunk.relativeOffset,
    byteLength: chunk.byteLength,
    record
  });
}

function borrowUnits(
  units: readonly ValidatedUnitPlan[],
  borrow: BorrowVerifiedVideoRange
): readonly BorrowedUnit[] {
  return Object.freeze(units.map((unit, unitIndex) => Object.freeze({
    id: unit.id,
    expectedDisplayedFrames: unit.expectedDisplayedFrames,
    chunks: Object.freeze(unit.chunks.map((chunk, chunkIndex) => {
      const bytes = borrow(chunk.blobKey, chunk.relativeOffset, chunk.byteLength);
      if (!(bytes instanceof Uint8Array) || bytes.byteLength !== chunk.byteLength) {
        invalid(
          `borrowed bytes for units[${String(unitIndex)}].chunks[${String(chunkIndex)}] are malformed`
        );
      }
      return Object.freeze({ ...chunk, bytes });
    }))
  })));
}

function normalizeSubmissionMetadata(
  units: readonly ValidatedUnitPlan[],
  syntaxUnits: readonly SyntaxUnitInspection[]
): readonly Readonly<VideoCodecUnitInspection>[] {
  if (syntaxUnits.length !== units.length) {
    invalid("codec inspection unit count disagrees with the manifest plan");
  }
  return Object.freeze(units.map((unit, unitIndex) => {
    const syntaxUnit = syntaxUnits[unitIndex];
    if (
      syntaxUnit === undefined ||
      syntaxUnit.id !== unit.id ||
      syntaxUnit.chunks.length !== unit.chunks.length
    ) {
      invalid(`codec inspection disagrees with units[${String(unitIndex)}]`);
    }

    const presentationIndices = unit.chunks.map(() => [] as number[]);
    const frames: Array<{
      readonly chunkIndex: number;
      readonly codedFrameIndex: number;
      readonly timestamp: number;
    }> = [];
    let displayedFrameCount = 0;
    for (let chunkIndex = 0; chunkIndex < unit.chunks.length; chunkIndex += 1) {
      const chunk = unit.chunks[chunkIndex]!;
      const syntax = syntaxUnit.chunks[chunkIndex]!;
      if (syntax.displayedFrameCount !== chunk.record.displayedFrameCount) {
        invalid(
          `bitstream displayed frame count disagrees with units[${String(unitIndex)}].chunks[${String(chunkIndex)}]`
        );
      }
      const expectedKey = syntax.chunkType === "key";
      if (chunk.record.randomAccess !== expectedKey) {
        invalid(
          `bitstream chunk type disagrees with units[${String(unitIndex)}].chunks[${String(chunkIndex)}]`
        );
      }
      displayedFrameCount += syntax.displayedFrameCount;
      if (!Number.isSafeInteger(displayedFrameCount)) {
        invalid(`units[${String(unitIndex)}] displayed frame count is unsafe`);
      }
      for (
        let codedFrameIndex = 0;
        codedFrameIndex < syntax.displayedFrameCount;
        codedFrameIndex += 1
      ) {
        frames.push({
          chunkIndex,
          codedFrameIndex,
          timestamp: checkedPresentationTimestamp(
            chunk.record.presentationTimestamp,
            chunk.record.duration,
            codedFrameIndex,
            `units[${String(unitIndex)}].chunks[${String(chunkIndex)}]`
          )
        });
      }
    }
    if (displayedFrameCount !== unit.expectedDisplayedFrames) {
      invalid(`unit ${unit.id} displayed frame count disagrees with the manifest plan`);
    }

    frames.sort((left, right) => left.timestamp - right.timestamp);
    for (let presentationIndex = 0; presentationIndex < frames.length; presentationIndex += 1) {
      const frame = frames[presentationIndex]!;
      if (
        presentationIndex > 0 &&
        frame.timestamp === frames[presentationIndex - 1]!.timestamp
      ) {
        invalid(`unit ${unit.id} contains duplicate presentation timestamps`);
      }
      presentationIndices[frame.chunkIndex]![frame.codedFrameIndex] = presentationIndex;
    }

    const submissions = Object.freeze(unit.chunks.map((chunk, chunkIndex) => {
      const syntax = syntaxUnit.chunks[chunkIndex]!;
      const indices = Object.freeze(presentationIndices[chunkIndex]!);
      if (
        syntax.expectedPresentationIndex !== undefined &&
        (indices.length !== 1 || indices[0] !== syntax.expectedPresentationIndex)
      ) {
        invalid(
          `bitstream presentation order disagrees with units[${String(unitIndex)}].chunks[${String(chunkIndex)}]`
        );
      }
      return Object.freeze({
        decodeIndex: chunkIndex,
        chunkType: syntax.chunkType,
        presentationTimestamp: chunk.record.presentationTimestamp,
        duration: chunk.record.duration,
        displayedFrameCount: syntax.displayedFrameCount,
        presentationIndices: indices
      });
    }));
    return Object.freeze({
      id: unit.id,
      displayedFrameCount,
      submissions
    });
  }));
}

function validateVp9KeyGeometry(
  units: ReturnType<typeof inspectVp9Rendition>["units"],
  rendition: Readonly<ProductionRendition>,
  geometry: Readonly<DecodedStorageGeometry>
): void {
  let keyFrameCount = 0;
  for (const unit of units) {
    for (const packet of unit.packets) {
      for (const frame of packet.codedFrames) {
        if (!frame.key) continue;
        keyFrameCount += 1;
        requireGeometry(frame.width, frame.height, rendition, "VP9 key frame");
        requireVisibleGeometry(
          frame.renderWidth,
          frame.renderHeight,
          geometry,
          "VP9 key frame"
        );
        requireBt709Limited(frame.color, "VP9 key frame");
      }
    }
  }
  if (keyFrameCount === 0) invalid("VP9 rendition contains no key-frame geometry");
}

function createDecoderConfig(
  codec: string,
  rendition: Readonly<ProductionRendition>,
  geometry: Readonly<DecodedStorageGeometry>
): Readonly<VideoDecoderConfig> {
  return Object.freeze({
    codec,
    codedWidth: rendition.codedWidth,
    codedHeight: rendition.codedHeight,
    displayAspectWidth: geometry.width,
    displayAspectHeight: geometry.height,
    colorSpace: BT709_LIMITED_COLOR_SPACE
  });
}

function validateRect(
  value: Rect,
  codedWidth: number,
  codedHeight: number,
  name: string
): Rect {
  if (!Array.isArray(value) || value.length !== 4) {
    invalid(`${name} must contain four integers`);
  }
  for (let index = 0; index < 4; index += 1) {
    if (!Object.prototype.hasOwnProperty.call(value, String(index))) {
      invalid(`${name} must be dense`);
    }
  }
  const [x, y, width, height] = value;
  requireNonNegativeSafeInteger(x, `${name} x`);
  requireNonNegativeSafeInteger(y, `${name} y`);
  if (!isPositiveSafeInteger(width) || !isPositiveSafeInteger(height)) {
    invalid(`${name} dimensions are invalid`);
  }
  if (x > codedWidth - width || y > codedHeight - height) {
    invalid(`${name} lies outside the coded rendition surface`);
  }
  return value;
}

function validateFrameRate(value: Readonly<{ numerator: number; denominator: number }>): void {
  if (
    value === null ||
    typeof value !== "object" ||
    !isPositiveSafeInteger(value.numerator) ||
    !isPositiveSafeInteger(value.denominator)
  ) {
    invalid("manifest frame rate is invalid");
  }
}

function freezeFrameRate(
  value: Readonly<{ numerator: number; denominator: number }>
): Readonly<{ numerator: number; denominator: number }> {
  return Object.freeze({ numerator: value.numerator, denominator: value.denominator });
}

function requireGeometry(
  width: number | undefined,
  height: number | undefined,
  rendition: Readonly<ProductionRendition>,
  source: string
): void {
  if (width !== rendition.codedWidth || height !== rendition.codedHeight) {
    invalid(`${source} coded geometry disagrees with the manifest rendition`);
  }
}

function requireVisibleGeometry(
  width: number | undefined,
  height: number | undefined,
  geometry: Readonly<DecodedStorageGeometry>,
  source: string
): void {
  if (width !== geometry.width || height !== geometry.height) {
    invalid(`${source} visible geometry disagrees with the manifest rendition`);
  }
}

function requireBt709Limited(
  color: {
    readonly fullRange: boolean;
    readonly colourPrimaries?: number;
    readonly colorPrimaries?: number;
    readonly transferCharacteristics?: number;
    readonly matrixCoefficients?: number;
  } | undefined,
  source: string
): void {
  const primaries = color?.colourPrimaries ?? color?.colorPrimaries;
  if (
    color?.fullRange !== false ||
    primaries !== 1 ||
    color.transferCharacteristics !== 1 ||
    color.matrixCoefficients !== 1
  ) {
    invalid(`${source} must signal BT.709 limited-range color`);
  }
}

function checkedPresentationTimestamp(
  timestamp: number,
  duration: number,
  frameIndex: number,
  path: string
): number {
  const result = BigInt(timestamp) + BigInt(duration) * BigInt(frameIndex);
  if (result > BigInt(Number.MAX_SAFE_INTEGER)) {
    invalid(`${path} presentation timeline exceeds the safe integer range`);
  }
  return Number(result);
}

function requireDenseNonEmptyArray(value: readonly unknown[], name: string): void {
  if (!Array.isArray(value) || value.length === 0) {
    invalid(`${name} must be a non-empty array`);
  }
  for (let index = 0; index < value.length; index += 1) {
    if (!Object.prototype.hasOwnProperty.call(value, String(index))) {
      invalid(`${name} must be dense`);
    }
  }
}

function isVideoCodecFamily(value: VideoCodec): value is VideoCodecFamily {
  return (VIDEO_CODEC_FAMILIES as readonly unknown[]).includes(value);
}

function isPositiveSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function requirePositiveEven(value: unknown, name: string): void {
  if (!isPositiveSafeInteger(value) || value % 2 !== 0) {
    invalid(`${name} must be a positive even safe integer`);
  }
}

function requireNonNegativeSafeInteger(value: unknown, name: string): void {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    invalid(`${name} must be a non-negative safe integer`);
  }
}

function alignEven(value: number): number {
  return value % 2 === 0 ? value : value + 1;
}

function exhaustiveFamily(value: never): never {
  return invalid(`unsupported codec family ${String(value)}`);
}

function invalid(message: string): never {
  throw new TypeError(`video codec adapter: ${message}`);
}
