import type {
  EncodedChunkRecord,
  ByteRange,
  Edge,
  Port,
  ParsedFrontIndex,
  ProductionRendition,
  State,
  Unit,
  UnitBlobRange
} from "@pixel-point/aval-format";

import {
  RuntimePlaybackError,
  normalizeRuntimeFailure,
  type RuntimeFailureContext
} from "./errors.js";

export interface RuntimeCatalogIdIndex<TValue> {
  readonly size: number;
  get(id: string): Readonly<TValue> | undefined;
  require(id: string): Readonly<TValue>;
  keys(): readonly string[];
  values(): readonly Readonly<TValue>[];
}

export interface RuntimeCatalogPortEntry {
  readonly unit: string;
  readonly port: Readonly<Port>;
}

export interface RuntimeCatalogPortIndex {
  readonly size: number;
  get(unit: string, port: string): Readonly<RuntimeCatalogPortEntry> | undefined;
  require(unit: string, port: string): Readonly<RuntimeCatalogPortEntry>;
  values(): readonly Readonly<RuntimeCatalogPortEntry>[];
}

export interface RuntimeCatalogChunk {
  readonly rendition: string;
  readonly unit: string;
  readonly decodeIndex: number;
  readonly ordinal: number;
  readonly record: Readonly<EncodedChunkRecord>;
  readonly blobKey?: string;
  readonly blobRange?: Readonly<UnitBlobRange>;
  readonly relativeRange?: Readonly<ByteRange>;
  readonly range: Readonly<ByteRange>;
}

export interface RuntimeCatalogChunkIndex {
  readonly size: number;
  get(
    rendition: string,
    unit: string,
    decodeIndex: number
  ): Readonly<RuntimeCatalogChunk> | undefined;
  require(
    rendition: string,
    unit: string,
    decodeIndex: number
  ): Readonly<RuntimeCatalogChunk>;
  values(): readonly Readonly<RuntimeCatalogChunk>[];
}

export interface CatalogMapBuildInput {
  readonly frontIndex: Readonly<ParsedFrontIndex>;
  readonly declaredFileLength: number;
}

export interface CatalogMaps {
  readonly renditions: Map<string, Readonly<ProductionRendition>>;
  readonly units: Map<string, Readonly<Unit>>;
  readonly states: Map<string, Readonly<State>>;
  readonly edges: Map<string, Readonly<Edge>>;
  readonly ports: Map<string, Readonly<RuntimeCatalogPortEntry>>;
  readonly chunks: Map<string, Readonly<RuntimeCatalogChunk>>;
}

export function buildCatalogMaps(
  input: Readonly<CatalogMapBuildInput>
): CatalogMaps {
  if (typeof input !== "object" || input === null) {
    throw indexError("asset catalog map input is invalid");
  }
  const frontIndex = input.frontIndex;
  const byteLength = input.declaredFileLength;
  if (
    typeof frontIndex !== "object" ||
    frontIndex === null ||
    !Number.isSafeInteger(byteLength) ||
    byteLength < 1 ||
    frontIndex.header?.declaredFileLength !== byteLength
  ) {
    throw indexError("asset catalog front-index geometry is invalid");
  }
  const manifest = frontIndex.manifest;
  const renditions = indexById<ProductionRendition>(
    manifest.renditions,
    "rendition"
  );
  const units = indexById<Unit>(manifest.units, "unit");
  const states = indexById<State>(manifest.states, "state");
  const edges = indexById<Edge>(manifest.edges, "edge");
  const ports = new Map<string, Readonly<RuntimeCatalogPortEntry>>();
  const chunks = new Map<string, Readonly<RuntimeCatalogChunk>>();
  const unitBlobs = indexUnitBlobs(frontIndex, byteLength);

  for (const unit of manifest.units) {
    if (unit.kind !== "body") continue;
    for (const port of unit.ports) {
      insertUnique(
        ports,
        portIdentity(unit.id, port.id),
        Object.freeze({ unit: unit.id, port }),
        "validated asset contains a duplicate body port"
      );
    }
  }

  for (const blob of unitBlobs.values()) {
    const rendition = renditions.get(blob.rendition);
    const unit = units.get(blob.unit);
    if (rendition === undefined || unit === undefined) {
      throw indexError("validated asset chunk span relation is missing");
    }
    const blobEnd = checkedCatalogRangeEnd(
      blob.offset,
      blob.length,
      byteLength
    );
    for (let decodeIndex = 0; decodeIndex < blob.chunkCount; decodeIndex += 1) {
      const ordinal = blob.chunkStart + decodeIndex;
      const record = frontIndex.records[ordinal];
      if (record === undefined) {
        throw indexError("validated asset chunk array is sparse");
      }
      const recordEnd = checkedCatalogRangeEnd(
        record.byteOffset,
        record.byteLength,
        byteLength
      );
      if (record.byteOffset < blob.offset || recordEnd > blobEnd) {
        throw indexError("validated asset chunk exceeds its unit blob");
      }
      const range = Object.freeze({
        offset: record.byteOffset,
        length: record.byteLength
      });
      const relativeRange = Object.freeze({
        offset: record.byteOffset - blob.offset,
        length: record.byteLength
      });
      insertUnique(
        chunks,
        chunkIdentity(rendition.id, unit.id, decodeIndex),
        Object.freeze({
          rendition: rendition.id,
          unit: unit.id,
          decodeIndex,
          ordinal,
          record,
          blobKey: runtimeUnitBlobKey(rendition.id, unit.id),
          blobRange: blob,
          relativeRange,
          range
        }),
        "validated asset contains a duplicate encoded-chunk identity"
      );
    }
  }

  return Object.freeze({
    renditions,
    units,
    states,
    edges,
    ports,
    chunks
  });
}

export function runtimeUnitBlobKey(rendition: string, unit: string): string {
  return `unit:${rendition}:${unit}`;
}

function indexUnitBlobs(
  frontIndex: Readonly<ParsedFrontIndex>,
  declaredFileLength: number
): ReadonlyMap<string, Readonly<UnitBlobRange>> {
  const result = new Map<string, Readonly<UnitBlobRange>>();
  for (const blob of frontIndex.unitBlobs) {
    checkedCatalogRangeEnd(blob.offset, blob.length, declaredFileLength);
    if (
      !Number.isSafeInteger(blob.chunkStart) ||
      !Number.isSafeInteger(blob.chunkCount) ||
      blob.chunkStart < 0 ||
      blob.chunkCount < 1 ||
      blob.chunkStart > frontIndex.records.length ||
      blob.chunkCount > frontIndex.records.length - blob.chunkStart
    ) {
      throw indexError("validated unit blob chunk span is invalid");
    }
    insertUnique(
      result,
      unitBlobIdentity(blob.rendition, blob.unit),
      blob,
      "validated asset contains a duplicate unit blob"
    );
  }
  return result;
}

export function createCatalogIdIndex<TValue>(
  label: string,
  map: () => ReadonlyMap<string, Readonly<TValue>>,
  context: (id: string) => Readonly<RuntimeFailureContext>
): RuntimeCatalogIdIndex<TValue> {
  return Object.freeze({
    get size(): number {
      return map().size;
    },
    get(id: string): Readonly<TValue> | undefined {
      return map().get(id);
    },
    require(id: string): Readonly<TValue> {
      const value = map().get(id);
      if (value === undefined) {
        throw indexError(`asset catalog ${label} lookup failed`, context(id));
      }
      return value;
    },
    keys(): readonly string[] {
      return Object.freeze([...map().keys()]);
    },
    values(): readonly Readonly<TValue>[] {
      return Object.freeze([...map().values()]);
    }
  });
}

export function createCatalogPortIndex(
  map: () => ReadonlyMap<string, Readonly<RuntimeCatalogPortEntry>>
): RuntimeCatalogPortIndex {
  return Object.freeze({
    get size(): number {
      return map().size;
    },
    get(
      unit: string,
      port: string
    ): Readonly<RuntimeCatalogPortEntry> | undefined {
      return map().get(portIdentity(unit, port));
    },
    require(unit: string, port: string): Readonly<RuntimeCatalogPortEntry> {
      const value = map().get(portIdentity(unit, port));
      if (value === undefined) {
        throw indexError("asset catalog port lookup failed", {
          unit,
          path: port
        });
      }
      return value;
    },
    values(): readonly Readonly<RuntimeCatalogPortEntry>[] {
      return Object.freeze([...map().values()]);
    }
  });
}

export function createCatalogChunkIndex(
  map: () => ReadonlyMap<string, Readonly<RuntimeCatalogChunk>>
): RuntimeCatalogChunkIndex {
  return Object.freeze({
    get size(): number {
      return map().size;
    },
    get(
      rendition: string,
      unit: string,
      decodeIndex: number
    ): Readonly<RuntimeCatalogChunk> | undefined {
      return map().get(chunkIdentity(rendition, unit, decodeIndex));
    },
    require(
      rendition: string,
      unit: string,
      decodeIndex: number
    ): Readonly<RuntimeCatalogChunk> {
      const value = map().get(chunkIdentity(rendition, unit, decodeIndex));
      if (value === undefined) {
        throw indexError("asset catalog encoded-chunk lookup failed", {
          rendition,
          unit,
          decodeIndex
        });
      }
      return value;
    },
    values(): readonly Readonly<RuntimeCatalogChunk>[] {
      return Object.freeze([...map().values()]);
    }
  });
}

export function checkedCatalogRangeEnd(
  offset: number,
  length: number,
  limit: number
): number {
  if (
    !Number.isSafeInteger(offset) ||
    !Number.isSafeInteger(length) ||
    offset < 0 ||
    length < 1 ||
    offset > limit ||
    length > limit - offset
  ) {
    throw indexError("validated asset byte range is unavailable");
  }
  return offset + length;
}

function indexById<TValue extends { readonly id: string }>(
  values: readonly Readonly<TValue>[],
  label: string
): Map<string, Readonly<TValue>> {
  const map = new Map<string, Readonly<TValue>>();
  for (const value of values) {
    insertUnique(
      map,
      value.id,
      value,
      `validated asset contains a duplicate ${label}`
    );
  }
  return map;
}

function insertUnique<TValue>(
  map: Map<string, TValue>,
  key: string,
  value: TValue,
  message: string
): void {
  if (map.has(key)) throw indexError(message);
  map.set(key, value);
}

function portIdentity(unit: string, port: string): string {
  return `${unit}/${port}`;
}

function unitBlobIdentity(rendition: string, unit: string): string {
  return runtimeUnitBlobKey(rendition, unit);
}

function chunkIdentity(
  rendition: string,
  unit: string,
  decodeIndex: number
): string {
  return `${rendition}/${unit}/${String(decodeIndex)}`;
}

function indexError(
  message: string,
  context: Readonly<RuntimeFailureContext> = {}
): RuntimePlaybackError {
  return new RuntimePlaybackError(
    normalizeRuntimeFailure("invalid-asset", message, context)
  );
}
