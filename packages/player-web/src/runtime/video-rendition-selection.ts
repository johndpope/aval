import {
  IDENTIFIER_PATTERN,
  PACKED_ALPHA_GUTTER,
  parseVideoCodecString,
  type AlphaLayout,
  type CompiledManifest,
  type ProductionRendition,
  type Rect,
  type VideoBitstream,
  type VideoCodec,
  type VideoRenditionGeometry
} from "@pixel-point/aval-format";

import type { DecoderWorkerProbeConfig } from "../decoder-worker/protocol.js";

export type VideoRenditionSelectionManifest = Pick<
  CompiledManifest,
  | "formatVersion"
  | "codec"
  | "bitstream"
  | "layout"
  | "canvas"
  | "frameRate"
  | "renditions"
>;

export interface VideoRenditionDecodedStorage {
  readonly width: number;
  readonly height: number;
  readonly rgbaBytes: number;
}

export interface VideoRenditionCandidate {
  readonly authoredIndex: number;
  readonly rendition: Readonly<ProductionRendition>;
  /** Exact codec-neutral texture/storage geometry retained through activation. */
  readonly geometry: Readonly<VideoRenditionGeometry>;
  readonly decoderConfig: Readonly<DecoderWorkerProbeConfig>;
  readonly decodedStorage: Readonly<VideoRenditionDecodedStorage>;
}

export type VideoRenditionAttemptOutcome =
  | "resource-ineligible"
  | "decoder-unsupported"
  | "selected";

export interface VideoRenditionSelectionAttempt {
  readonly authoredIndex: number;
  readonly rendition: string;
  readonly outcome: VideoRenditionAttemptOutcome;
}

export type VideoRenditionSelectionResult =
  | {
      readonly outcome: "selected";
      readonly selected: Readonly<VideoRenditionCandidate>;
      readonly attempts: readonly Readonly<VideoRenditionSelectionAttempt>[];
    }
  | {
      /** Deterministic: every rendition was resource-ineligible or unsupported. */
      readonly outcome: "all-unsupported";
      readonly selected: null;
      readonly attempts: readonly Readonly<VideoRenditionSelectionAttempt>[];
    };

export type VideoRenditionResourceEligibility = (
  candidate: Readonly<VideoRenditionCandidate>
) => boolean;

export type ExactVideoDecoderConfigProbe = (
  config: Readonly<DecoderWorkerProbeConfig>,
  candidate: Readonly<VideoRenditionCandidate>
) => Promise<boolean>;

export interface VideoRenditionSelectionInput {
  readonly manifest: Readonly<VideoRenditionSelectionManifest>;
  readonly isResourceEligible: VideoRenditionResourceEligibility;
  readonly probeDecoderConfig: ExactVideoDecoderConfigProbe;
}

const EXPECTED_BITSTREAM = Object.freeze({
  h264: "annex-b",
  h265: "annex-b",
  vp9: "frame",
  av1: "low-overhead"
} as const satisfies Readonly<Record<VideoCodec, VideoBitstream>>);

const BT709_LIMITED_COLOR_SPACE = Object.freeze({
  primaries: "bt709" as const,
  transfer: "bt709" as const,
  matrix: "bt709" as const,
  fullRange: false as const
});

/**
 * Select one rendition from a single wire-1.0 asset without reordering its
 * authored quality ladder. A rejected support probe is deterministic; a probe
 * throw/rejection is terminal and deliberately propagates to the caller.
 */
export async function selectVideoRendition(
  input: Readonly<VideoRenditionSelectionInput>
): Promise<Readonly<VideoRenditionSelectionResult>> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    invalid("input must be an object");
  }
  if (typeof input.isResourceEligible !== "function") {
    invalid("resource eligibility predicate is unavailable");
  }
  if (typeof input.probeDecoderConfig !== "function") {
    invalid("decoder configuration probe is unavailable");
  }

  const candidates = createVideoRenditionCandidates(input.manifest);
  const attempts: VideoRenditionSelectionAttempt[] = [];
  for (const candidate of candidates) {
    const resourceEligible = input.isResourceEligible(candidate);
    if (typeof resourceEligible !== "boolean") {
      invalid("resource eligibility predicate must return a boolean");
    }
    if (!resourceEligible) {
      attempts.push(createAttempt(candidate, "resource-ineligible"));
      continue;
    }

    const supported = await input.probeDecoderConfig(
      candidate.decoderConfig,
      candidate
    );
    if (typeof supported !== "boolean") {
      invalid("decoder configuration probe must resolve to a boolean");
    }
    if (!supported) {
      attempts.push(createAttempt(candidate, "decoder-unsupported"));
      continue;
    }

    attempts.push(createAttempt(candidate, "selected"));
    return Object.freeze({
      outcome: "selected" as const,
      selected: candidate,
      attempts: Object.freeze(attempts)
    });
  }

  return Object.freeze({
    outcome: "all-unsupported" as const,
    selected: null,
    attempts: Object.freeze(attempts)
  });
}

/** Validate and detach the authored rendition ladder before asynchronous work. */
export function createVideoRenditionCandidates(
  manifest: Readonly<VideoRenditionSelectionManifest>
): readonly Readonly<VideoRenditionCandidate>[] {
  validateManifestEnvelope(manifest);
  const seenIds = new Set<string>();
  const candidates = manifest.renditions.map((rendition, authoredIndex) => {
    const path = `renditions[${String(authoredIndex)}]`;
    const detached = cloneRendition(
      rendition,
      manifest,
      path
    );
    if (seenIds.has(detached.id)) invalid(`${path} id is duplicated`);
    seenIds.add(detached.id);
    const decodedStorage = deriveDecodedStorage(detached, manifest, path);
    const geometry = createRenditionGeometry(
      detached,
      manifest.layout,
      decodedStorage,
      path
    );
    const decoderConfig = Object.freeze({
      codec: detached.codec,
      codedWidth: detached.codedWidth,
      codedHeight: detached.codedHeight,
      displayAspectWidth: decodedStorage.width,
      displayAspectHeight: decodedStorage.height,
      colorSpace: BT709_LIMITED_COLOR_SPACE
    });
    return Object.freeze({
      authoredIndex,
      rendition: detached,
      geometry,
      decoderConfig,
      decodedStorage
    });
  });
  return Object.freeze(candidates);
}

function createRenditionGeometry(
  rendition: Readonly<ProductionRendition>,
  layout: VideoRenditionSelectionManifest["layout"],
  decodedStorage: Readonly<VideoRenditionDecodedStorage>,
  path: string
): Readonly<VideoRenditionGeometry> {
  const visibleColorRect = rendition.alphaLayout.colorRect;
  const visibleAlphaRect = rendition.alphaLayout.type === "stacked"
    ? rendition.alphaLayout.alphaRect
    : undefined;
  return Object.freeze({
    layout,
    visibleColorRect,
    ...(visibleAlphaRect === undefined ? {} : { visibleAlphaRect }),
    decodedStorageRect: Object.freeze([
      0,
      0,
      decodedStorage.width,
      decodedStorage.height
    ]) as Rect,
    codedWidth: rendition.codedWidth,
    codedHeight: rendition.codedHeight,
    visibleColorArea: checkedProduct(
      visibleColorRect[2],
      visibleColorRect[3],
      `${path} visible color area`
    ),
    decodedRgbaBytes: decodedStorage.rgbaBytes,
    codedRgbaBytes: checkedProduct(
      checkedProduct(
        rendition.codedWidth,
        rendition.codedHeight,
        `${path} coded pixels`
      ),
      4,
      `${path} coded RGBA bytes`
    )
  });
}

function validateManifestEnvelope(
  manifest: Readonly<VideoRenditionSelectionManifest>
): void {
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    invalid("manifest must be an object");
  }
  if (manifest.formatVersion !== "1.0") {
    invalid("manifest must use wire format 1.0");
  }
  if (!isCodecFamily(manifest.codec)) {
    invalid("manifest codec family is unsupported");
  }
  if (manifest.bitstream !== EXPECTED_BITSTREAM[manifest.codec]) {
    invalid(
      `manifest ${manifest.codec} bitstream must be ${EXPECTED_BITSTREAM[manifest.codec]}`
    );
  }
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
  if (
    manifest.frameRate === null ||
    typeof manifest.frameRate !== "object" ||
    !isPositiveSafeInteger(manifest.frameRate.numerator) ||
    !isPositiveSafeInteger(manifest.frameRate.denominator)
  ) {
    invalid("manifest frame rate is invalid");
  }
  requireDenseNonEmptyArray(manifest.renditions, "manifest renditions");
}

function cloneRendition(
  rendition: Readonly<ProductionRendition>,
  manifest: Readonly<VideoRenditionSelectionManifest>,
  path: string
): Readonly<ProductionRendition> {
  if (rendition === null || typeof rendition !== "object" || Array.isArray(rendition)) {
    invalid(`${path} must be an object`);
  }
  if (typeof rendition.id !== "string" || !IDENTIFIER_PATTERN.test(rendition.id)) {
    invalid(`${path} id is invalid`);
  }
  const parsedCodec = parseVideoCodecString(rendition.codec);
  if (parsedCodec?.family !== manifest.codec) {
    invalid(`${path} codec disagrees with the manifest family`);
  }
  if (rendition.bitDepth !== 8 && rendition.bitDepth !== 10) {
    invalid(`${path} bit depth is invalid`);
  }
  if (manifest.codec !== "av1" && rendition.bitDepth !== 8) {
    invalid(`${path} ${manifest.codec} rendition must be 8-bit`);
  }
  if (!codecBitDepthMatches(rendition.codec, manifest.codec, rendition.bitDepth)) {
    invalid(`${path} codec string disagrees with its bit depth`);
  }
  requirePositiveEven(rendition.codedWidth, `${path} coded width`);
  requirePositiveEven(rendition.codedHeight, `${path} coded height`);
  if (
    rendition.bitrate === null ||
    typeof rendition.bitrate !== "object" ||
    !isPositiveSafeInteger(rendition.bitrate.average) ||
    !isPositiveSafeInteger(rendition.bitrate.peak) ||
    rendition.bitrate.average > rendition.bitrate.peak
  ) {
    invalid(`${path} bitrate is invalid`);
  }

  const alphaLayout = cloneAlphaLayout(
    rendition.alphaLayout,
    manifest.layout,
    rendition.codedWidth,
    rendition.codedHeight,
    path
  );
  return Object.freeze({
    id: rendition.id,
    codec: rendition.codec,
    bitDepth: rendition.bitDepth,
    codedWidth: rendition.codedWidth,
    codedHeight: rendition.codedHeight,
    alphaLayout,
    bitrate: Object.freeze({
      average: rendition.bitrate.average,
      peak: rendition.bitrate.peak
    })
  });
}

function cloneAlphaLayout(
  value: Readonly<AlphaLayout>,
  manifestLayout: VideoRenditionSelectionManifest["layout"],
  codedWidth: number,
  codedHeight: number,
  path: string
): Readonly<AlphaLayout> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid(`${path} alpha layout is invalid`);
  }
  if (manifestLayout === "opaque") {
    if (value.type !== "opaque") {
      invalid(`${path} alpha layout disagrees with the manifest layout`);
    }
    return Object.freeze({
      type: "opaque" as const,
      colorRect: cloneRect(
        value.colorRect,
        codedWidth,
        codedHeight,
        `${path}.alphaLayout.colorRect`
      )
    });
  }
  if (value.type !== "stacked") {
    invalid(`${path} alpha layout disagrees with the manifest layout`);
  }
  return Object.freeze({
    type: "stacked" as const,
    colorRect: cloneRect(
      value.colorRect,
      codedWidth,
      codedHeight,
      `${path}.alphaLayout.colorRect`
    ),
    alphaRect: cloneRect(
      value.alphaRect,
      codedWidth,
      codedHeight,
      `${path}.alphaLayout.alphaRect`
    )
  });
}

function deriveDecodedStorage(
  rendition: Readonly<ProductionRendition>,
  manifest: Readonly<VideoRenditionSelectionManifest>,
  path: string
): Readonly<VideoRenditionDecodedStorage> {
  const colorRect = rendition.alphaLayout.colorRect;
  if (colorRect[0] !== 0 || colorRect[1] !== 0) {
    invalid(`${path} color rectangle must begin at the decoded origin`);
  }
  if (colorRect[2] > manifest.canvas.width || colorRect[3] > manifest.canvas.height) {
    invalid(`${path} color rectangle does not fit the manifest canvas`);
  }
  if (
    BigInt(colorRect[2]) * BigInt(manifest.canvas.height) !==
    BigInt(colorRect[3]) * BigInt(manifest.canvas.width)
  ) {
    invalid(`${path} color rectangle disagrees with the manifest canvas aspect ratio`);
  }
  const width = alignEven(colorRect[2]);
  const paneHeight = alignEven(colorRect[3]);
  let height = paneHeight;
  if (rendition.alphaLayout.type === "stacked") {
    const alphaRect = rendition.alphaLayout.alphaRect;
    if (
      alphaRect[0] !== 0 ||
      alphaRect[1] !== paneHeight + PACKED_ALPHA_GUTTER ||
      alphaRect[2] !== colorRect[2] ||
      alphaRect[3] !== colorRect[3]
    ) {
      invalid(`${path} alpha rectangle disagrees with packed-alpha geometry`);
    }
    height = checkedAdd(
      checkedProduct(paneHeight, 2, `${path} decoded storage height`),
      PACKED_ALPHA_GUTTER,
      `${path} decoded storage height`
    );
  }
  if (width > rendition.codedWidth || height > rendition.codedHeight) {
    invalid(`${path} decoded storage exceeds the coded surface`);
  }
  const rgbaBytes = checkedProduct(
    checkedProduct(width, height, `${path} decoded storage pixels`),
    4,
    `${path} decoded storage RGBA bytes`
  );
  return Object.freeze({ width, height, rgbaBytes });
}

function cloneRect(
  value: Rect,
  codedWidth: number,
  codedHeight: number,
  path: string
): Rect {
  if (!Array.isArray(value) || value.length !== 4) {
    invalid(`${path} must contain four integers`);
  }
  for (let index = 0; index < 4; index += 1) {
    if (!Object.prototype.hasOwnProperty.call(value, String(index))) {
      invalid(`${path} must be dense`);
    }
  }
  const [x, y, width, height] = value;
  requireNonNegativeSafeInteger(x, `${path}[0]`);
  requireNonNegativeSafeInteger(y, `${path}[1]`);
  if (!isPositiveSafeInteger(width) || !isPositiveSafeInteger(height)) {
    invalid(`${path} dimensions are invalid`);
  }
  if (x > codedWidth - width || y > codedHeight - height) {
    invalid(`${path} lies outside the coded surface`);
  }
  return Object.freeze([x, y, width, height]);
}

function codecBitDepthMatches(
  codec: string,
  family: VideoCodec,
  bitDepth: 8 | 10
): boolean {
  if (family !== "vp9" && family !== "av1") return bitDepth === 8;
  const terms = codec.split(".");
  return terms[3] === String(bitDepth).padStart(2, "0");
}

function createAttempt(
  candidate: Readonly<VideoRenditionCandidate>,
  outcome: VideoRenditionAttemptOutcome
): Readonly<VideoRenditionSelectionAttempt> {
  return Object.freeze({
    authoredIndex: candidate.authoredIndex,
    rendition: candidate.rendition.id,
    outcome
  });
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

function isCodecFamily(value: unknown): value is VideoCodec {
  return value === "h264" || value === "h265" || value === "vp9" || value === "av1";
}

function isPositiveSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function requirePositiveEven(value: unknown, path: string): void {
  if (!isPositiveSafeInteger(value) || value % 2 !== 0) {
    invalid(`${path} must be a positive even safe integer`);
  }
}

function requireNonNegativeSafeInteger(value: unknown, path: string): void {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    invalid(`${path} must be a non-negative safe integer`);
  }
}

function alignEven(value: number): number {
  return value % 2 === 0 ? value : checkedAdd(value, 1, "decoded storage alignment");
}

function checkedAdd(left: number, right: number, path: string): number {
  if (left > Number.MAX_SAFE_INTEGER - right) {
    invalid(`${path} exceeds the safe integer range`);
  }
  return left + right;
}

function checkedProduct(left: number, right: number, path: string): number {
  if (left !== 0 && right > Math.floor(Number.MAX_SAFE_INTEGER / left)) {
    invalid(`${path} exceeds the safe integer range`);
  }
  return left * right;
}

function invalid(message: string): never {
  throw new TypeError(`video rendition selection: ${message}`);
}
