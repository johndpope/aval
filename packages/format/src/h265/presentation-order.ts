import {
  isH265IdrNalType,
  isH265RandomAccessNalType
} from "./annex-b.js";
import { requireH265 } from "./failure.js";

export interface H265PictureOrderState {
  initialized: boolean;
  previousTid0PictureOrderCountLsb: number;
  previousTid0PictureOrderCountMsb: number;
}

export interface H265DecodedPictureOrder {
  readonly decodeIndex: number;
  readonly pictureOrderCount: number;
}

export function createH265PictureOrderState(): H265PictureOrderState {
  return {
    initialized: false,
    previousTid0PictureOrderCountLsb: 0,
    previousTid0PictureOrderCountMsb: 0
  };
}

/** Derives PicOrderCntVal with unit-local state (HEVC 8.3.1 subset). */
export function deriveH265PictureOrderCount(
  nalType: number,
  temporalId: number,
  pictureOrderCountLsb: number,
  log2MaxPictureOrderCountLsb: number,
  state: H265PictureOrderState
): number {
  const maximum = 2 ** log2MaxPictureOrderCountLsb;
  requireH265(
    Number.isSafeInteger(pictureOrderCountLsb) &&
      pictureOrderCountLsb >= 0 &&
      pictureOrderCountLsb < maximum,
    "pictureOrderCount",
    "slice picture-order-count LSB is out of range"
  );
  if (isH265IdrNalType(nalType)) {
    state.initialized = true;
    state.previousTid0PictureOrderCountLsb = 0;
    state.previousTid0PictureOrderCountMsb = 0;
    return 0;
  }
  let msb = 0;
  if (state.initialized && !isH265RandomAccessNalType(nalType)) {
    const previousLsb = state.previousTid0PictureOrderCountLsb;
    const previousMsb = state.previousTid0PictureOrderCountMsb;
    if (pictureOrderCountLsb < previousLsb && previousLsb - pictureOrderCountLsb >= maximum / 2) {
      msb = previousMsb + maximum;
    } else if (
      pictureOrderCountLsb > previousLsb &&
      pictureOrderCountLsb - previousLsb > maximum / 2
    ) {
      msb = previousMsb - maximum;
    } else {
      msb = previousMsb;
    }
  }
  const pictureOrderCount = msb + pictureOrderCountLsb;
  // RADL/RASL pictures (types 6..9) do not become prevTid0Pic.
  if (temporalId === 0 && !(nalType >= 6 && nalType <= 9)) {
    state.initialized = true;
    state.previousTid0PictureOrderCountLsb = pictureOrderCountLsb;
    state.previousTid0PictureOrderCountMsb = msb;
  }
  return pictureOrderCount;
}

/** Maps decoder submission order to a contiguous unit-local display order. */
export function deriveH265PresentationOrder(
  pictures: readonly H265DecodedPictureOrder[],
  maximumReorderPictures: number,
  path: string
): readonly number[] {
  requireH265(pictures.length > 0, path, "unit contains no decoded pictures");
  const sorted = [...pictures].sort(
    (left, right) => left.pictureOrderCount - right.pictureOrderCount
  );
  const first = sorted[0]?.pictureOrderCount;
  requireH265(first !== undefined, path, "unit contains no presentation pictures");
  const decodeToPresentation = new Array<number>(pictures.length);
  for (let presentationIndex = 0; presentationIndex < sorted.length; presentationIndex += 1) {
    const picture = sorted[presentationIndex];
    requireH265(picture !== undefined, path, "presentation picture is missing");
    requireH265(
      picture.pictureOrderCount === first + presentationIndex,
      path,
      "unit picture-order counts must be unique and contiguous"
    );
    requireH265(
      Number.isSafeInteger(picture.decodeIndex) &&
        picture.decodeIndex >= 0 &&
        picture.decodeIndex < pictures.length &&
        decodeToPresentation[picture.decodeIndex] === undefined,
      path,
      "unit decode index is duplicated or out of range"
    );
    decodeToPresentation[picture.decodeIndex] = presentationIndex;
  }
  let requiredReorder = 0;
  for (let decodeIndex = 0; decodeIndex < decodeToPresentation.length; decodeIndex += 1) {
    const presentationIndex = decodeToPresentation[decodeIndex];
    requireH265(presentationIndex !== undefined, path, "decode order has a gap");
    requiredReorder = Math.max(requiredReorder, decodeIndex - presentationIndex);
  }
  requireH265(
    requiredReorder <= maximumReorderPictures,
    path,
    "derived presentation reordering exceeds the SPS declaration"
  );
  return Object.freeze(decodeToPresentation);
}
