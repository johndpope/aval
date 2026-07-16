import { FormatError } from "../errors.js";
import type { Rect } from "../model.js";
import type {
  VideoRenditionGeometry,
  VideoRenditionGeometryInput
} from "./model.js";

export const PACKED_ALPHA_GUTTER = 8;

/**
 * Derive the shared opaque/packed-alpha storage geometry for one codec policy.
 * Codec adapters own the encoded-surface alignment; this function owns every
 * cross-codec packing and decoded-byte calculation.
 */
export function deriveVideoRenditionGeometry(
  input: VideoRenditionGeometryInput
): Readonly<VideoRenditionGeometry> {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    invalid("video geometry must be an object");
  }
  const canvasWidth = positive(input.canvasWidth, "canvasWidth");
  const canvasHeight = positive(input.canvasHeight, "canvasHeight");
  const visibleWidth = positive(input.visibleWidth, "visibleWidth");
  const visibleHeight = positive(input.visibleHeight, "visibleHeight");
  if (visibleWidth > canvasWidth || visibleHeight > canvasHeight) {
    invalid("visible color rectangle must fit the logical canvas");
  }
  if (
    BigInt(visibleWidth) * BigInt(canvasHeight) !==
    BigInt(visibleHeight) * BigInt(canvasWidth)
  ) {
    invalid("visible color rectangle must retain the canvas aspect ratio");
  }
  if (input.layout !== "opaque" && input.layout !== "packed-alpha") {
    invalid("layout must be opaque or packed-alpha");
  }
  if (
    typeof input.storage !== "object" ||
    input.storage === null ||
    Array.isArray(input.storage)
  ) {
    invalid("storage policy must be an object");
  }
  const widthAlignment = positive(
    input.storage.widthAlignment,
    "storage.widthAlignment"
  );
  const heightAlignment = positive(
    input.storage.heightAlignment,
    "storage.heightAlignment"
  );

  // Every supported production profile is 4:2:0, so each pane is even before
  // codec-specific padding is applied.
  const paneWidth = align(visibleWidth, 2, "visibleWidth");
  const paneHeight = align(visibleHeight, 2, "visibleHeight");
  const visibleColorRect = freezeRect(0, 0, visibleWidth, visibleHeight);
  let storageHeight = paneHeight;
  let visibleAlphaRect: Rect | undefined;
  if (input.layout === "packed-alpha") {
    visibleAlphaRect = freezeRect(
      0,
      add(paneHeight, PACKED_ALPHA_GUTTER, "alpha y"),
      visibleWidth,
      visibleHeight
    );
    storageHeight = add(
      product(2, paneHeight, "packed height"),
      PACKED_ALPHA_GUTTER,
      "packed height"
    );
  }

  const codedWidth = align(paneWidth, widthAlignment, "codedWidth");
  const codedHeight = align(storageHeight, heightAlignment, "codedHeight");
  const decodedStorageRect = freezeRect(0, 0, paneWidth, storageHeight);
  const visibleColorArea = product(
    visibleWidth,
    visibleHeight,
    "visible color area"
  );
  const decodedRgbaBytes = product(
    product(paneWidth, storageHeight, "decoded pixels"),
    4,
    "decoded RGBA bytes"
  );
  const codedRgbaBytes = product(
    product(codedWidth, codedHeight, "coded pixels"),
    4,
    "coded RGBA bytes"
  );

  return Object.freeze({
    layout: input.layout,
    visibleColorRect,
    ...(visibleAlphaRect === undefined ? {} : { visibleAlphaRect }),
    decodedStorageRect,
    codedWidth,
    codedHeight,
    visibleColorArea,
    decodedRgbaBytes,
    codedRgbaBytes
  });
}

function positive(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
    invalid(`${path} must be a positive safe integer`);
  }
  return value;
}

function align(value: number, alignment: number, path: string): number {
  const remainder = value % alignment;
  return remainder === 0 ? value : add(value, alignment - remainder, path);
}

function add(left: number, right: number, path: string): number {
  if (left > Number.MAX_SAFE_INTEGER - right) {
    invalid(`${path} exceeds the safe integer range`);
  }
  return left + right;
}

function product(left: number, right: number, path: string): number {
  if (left !== 0 && right > Math.floor(Number.MAX_SAFE_INTEGER / left)) {
    invalid(`${path} exceeds the safe integer range`);
  }
  return left * right;
}

function freezeRect(x: number, y: number, width: number, height: number): Rect {
  return Object.freeze([x, y, width, height]) as Rect;
}

function invalid(message: string): never {
  throw new FormatError("PROFILE_INVALID", message);
}
