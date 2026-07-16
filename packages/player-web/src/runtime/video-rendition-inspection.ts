import type {
  CompiledManifest,
  EncodedChunkRecord,
  ProductionRendition,
  Unit
} from "@pixel-point/aval-format";

import type {
  RuntimeAssetCatalog,
  RuntimeCatalogChunk,
  RuntimeCatalogChunkIndex,
  RuntimeCatalogIdIndex
} from "./asset-catalog.js";
import {
  inspectBorrowedVideoRendition,
  type BorrowedVideoRenditionPlan,
  type VideoCodecAdapterInspection
} from "./video-codec-adapters.js";
import type { VideoRenditionCandidate } from "./video-rendition-selection.js";

export interface InspectedVideoRendition {
  readonly candidate: Readonly<VideoRenditionCandidate>;
  readonly inspection: Readonly<VideoCodecAdapterInspection>;
}

interface VideoInspectionCatalog {
  readonly manifest: Readonly<CompiledManifest>;
  readonly renditions: Pick<RuntimeCatalogIdIndex<ProductionRendition>, "require">;
  readonly units: Pick<RuntimeCatalogIdIndex<Unit>, "require">;
  readonly chunks: Pick<RuntimeCatalogChunkIndex, "require">;
  copyChunk(rendition: string, unit: string, decodeIndex: number): ArrayBuffer;
}

interface PlannedChunkCopy {
  readonly entry: Readonly<RuntimeCatalogChunk>;
  readonly unit: string;
  readonly decodeIndex: number;
}

/**
 * Certify exactly the rendition selected by the source probe. The catalog is
 * the only byte authority and every temporary copy remains inside the format
 * inspector call; the returned value contains decoder metadata only.
 */
export function inspectSelectedVideoRendition(
  catalog: RuntimeAssetCatalog,
  candidate: Readonly<VideoRenditionCandidate>
): Readonly<InspectedVideoRendition> {
  const source = catalog as VideoInspectionCatalog;
  validateSelectedCandidate(source, candidate);
  const rendition = source.renditions.require(candidate.rendition.id);
  const copies = new Map<string, PlannedChunkCopy>();
  const units = source.manifest.units.map((unit) => {
    const installedUnit = source.units.require(unit.id);
    if (installedUnit !== unit && !sameUnitIdentity(installedUnit, unit)) {
      invalid("selected rendition unit identity diverged from the catalog");
    }
    const span = unit.chunks.find(({ rendition: id }) => id === rendition.id);
    if (span === undefined) {
      invalid("selected rendition is missing a unit chunk span");
    }
    if (
      span.frameCount !== unit.frameCount ||
      !Number.isSafeInteger(span.chunkCount) ||
      span.chunkCount < 1
    ) {
      invalid("selected rendition unit chunk span is malformed");
    }
    const chunks = Array.from({ length: span.chunkCount }, (_, decodeIndex) => {
      const entry = source.chunks.require(rendition.id, unit.id, decodeIndex);
      const blobKey = entry.blobKey;
      const relativeRange = entry.relativeRange;
      if (
        typeof blobKey !== "string" ||
        blobKey.length === 0 ||
        relativeRange === undefined ||
        !Number.isSafeInteger(relativeRange.offset) ||
        relativeRange.offset < 0 ||
        !Number.isSafeInteger(relativeRange.length) ||
        relativeRange.length < 1 ||
        relativeRange.length !== entry.record.byteLength
      ) {
        invalid("selected rendition chunk range is malformed");
      }
      const identity = rangeIdentity(
        blobKey,
        relativeRange.offset,
        relativeRange.length
      );
      if (copies.has(identity)) {
        invalid("selected rendition contains a duplicate chunk range");
      }
      copies.set(identity, Object.freeze({ entry, unit: unit.id, decodeIndex }));
      return Object.freeze({
        blobKey,
        relativeOffset: relativeRange.offset,
        byteLength: relativeRange.length,
        record: cloneRecord(entry.record)
      });
    });
    return Object.freeze({
      id: unit.id,
      expectedDisplayedFrames: unit.frameCount,
      chunks: Object.freeze(chunks)
    });
  });

  const plan: Readonly<BorrowedVideoRenditionPlan> = Object.freeze({
    manifest: source.manifest,
    rendition,
    units: Object.freeze(units)
  });
  const inspection = inspectBorrowedVideoRendition(
    plan,
    (blobKey, relativeOffset, byteLength) => {
      const copy = copies.get(rangeIdentity(blobKey, relativeOffset, byteLength));
      if (copy === undefined) {
        invalid("codec inspector requested an unplanned chunk range");
      }
      const data = source.copyChunk(
        rendition.id,
        copy.unit,
        copy.decodeIndex
      );
      if (!(data instanceof ArrayBuffer) || data.byteLength !== byteLength) {
        invalid("catalog returned a malformed selected-rendition chunk copy");
      }
      return new Uint8Array(data);
    }
  );
  if (!sameDecoderConfig(inspection.decoderConfig, candidate.decoderConfig)) {
    invalid("inspected decoder configuration disagrees with source selection");
  }
  return Object.freeze({ candidate, inspection });
}

/** Validate source-selection identity without borrowing encoded payloads. */
export function assertSelectedVideoRenditionCatalogIdentity(
  catalog: RuntimeAssetCatalog,
  candidate: Readonly<VideoRenditionCandidate>
): void {
  validateSelectedCandidate(catalog as VideoInspectionCatalog, candidate);
}

function validateSelectedCandidate(
  catalog: VideoInspectionCatalog,
  candidate: Readonly<VideoRenditionCandidate>
): void {
  if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) {
    invalid("selected rendition candidate is malformed");
  }
  if (
    !Number.isSafeInteger(candidate.authoredIndex) ||
    candidate.authoredIndex < 0 ||
    candidate.authoredIndex >= catalog.manifest.renditions.length
  ) {
    invalid("selected rendition authored index is invalid");
  }
  const authored = catalog.manifest.renditions[candidate.authoredIndex];
  const installed = catalog.renditions.require(candidate.rendition.id);
  if (
    authored === undefined ||
    !sameRendition(authored, candidate.rendition) ||
    !sameRendition(installed, candidate.rendition)
  ) {
    invalid("selected rendition does not belong to this asset catalog");
  }
}

function sameRendition(
  left: Readonly<ProductionRendition>,
  right: Readonly<ProductionRendition>
): boolean {
  return left.id === right.id &&
    left.codec === right.codec &&
    left.bitDepth === right.bitDepth &&
    left.codedWidth === right.codedWidth &&
    left.codedHeight === right.codedHeight &&
    left.bitrate.average === right.bitrate.average &&
    left.bitrate.peak === right.bitrate.peak &&
    left.alphaLayout.type === right.alphaLayout.type &&
    sameRect(left.alphaLayout.colorRect, right.alphaLayout.colorRect) &&
    (
      left.alphaLayout.type === "opaque" ||
      (
        right.alphaLayout.type === "stacked" &&
        sameRect(left.alphaLayout.alphaRect, right.alphaLayout.alphaRect)
      )
    );
}

function sameUnitIdentity(left: Readonly<Unit>, right: Readonly<Unit>): boolean {
  return left.id === right.id &&
    left.kind === right.kind &&
    left.frameCount === right.frameCount;
}

function sameRect(
  left: readonly number[],
  right: readonly number[]
): boolean {
  return left.length === right.length &&
    left.every((value, index) => value === right[index]);
}

function cloneRecord(
  record: Readonly<EncodedChunkRecord>
): Readonly<EncodedChunkRecord> {
  return Object.freeze({
    byteOffset: record.byteOffset,
    byteLength: record.byteLength,
    presentationTimestamp: record.presentationTimestamp,
    duration: record.duration,
    randomAccess: record.randomAccess,
    displayedFrameCount: record.displayedFrameCount
  });
}

function sameDecoderConfig(
  left: Readonly<VideoDecoderConfig>,
  right: Readonly<VideoDecoderConfig>
): boolean {
  return left.codec === right.codec &&
    left.codedWidth === right.codedWidth &&
    left.codedHeight === right.codedHeight &&
    left.displayAspectWidth === right.displayAspectWidth &&
    left.displayAspectHeight === right.displayAspectHeight &&
    left.colorSpace?.primaries === right.colorSpace?.primaries &&
    left.colorSpace?.transfer === right.colorSpace?.transfer &&
    left.colorSpace?.matrix === right.colorSpace?.matrix &&
    left.colorSpace?.fullRange === right.colorSpace?.fullRange &&
    !Object.hasOwn(left, "description") &&
    !Object.hasOwn(right, "description");
}

function rangeIdentity(
  blobKey: string,
  relativeOffset: number,
  byteLength: number
): string {
  return `${blobKey}\u0000${String(relativeOffset)}\u0000${String(byteLength)}`;
}

function invalid(message: string): never {
  throw new TypeError(`selected video rendition: ${message}`);
}
