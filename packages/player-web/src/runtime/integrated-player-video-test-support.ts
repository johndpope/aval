import type { RuntimeAssetCatalog } from "./asset-catalog.js";
import { installRuntimeAssetCatalog } from "./asset-catalog.js";
import {
  createVideoRenditionCandidates,
  type VideoRenditionCandidate
} from "./video-rendition-selection.js";

/**
 * Build the exact codec-neutral selection token that production source
 * selection hands to IntegratedPlayer. Byte inputs use a temporary catalog;
 * the returned candidate is fully detached before that catalog is retired.
 */
export function selectIntegratedTestVideoRendition(
  source: Uint8Array | RuntimeAssetCatalog,
  authoredIndex = 0
): Readonly<VideoRenditionCandidate> {
  const ownsCatalog = source instanceof Uint8Array;
  const catalog = ownsCatalog ? installRuntimeAssetCatalog(source) : source;
  try {
    const selected = createVideoRenditionCandidates(
      catalog.manifest
    )[authoredIndex];
    if (selected === undefined) {
      throw new RangeError("integrated test rendition index is unavailable");
    }
    return selected;
  } finally {
    if (ownsCatalog) catalog.dispose();
  }
}

/** Pair owned test bytes with their detached source-selection authority. */
export function createIntegratedTestVideoSource(
  bytes: Uint8Array,
  authoredIndex = 0
): Readonly<{
  readonly bytes: Uint8Array;
  readonly selectedRendition: Readonly<VideoRenditionCandidate>;
}> {
  return Object.freeze({
    bytes,
    selectedRendition: selectIntegratedTestVideoRendition(bytes, authoredIndex)
  });
}
