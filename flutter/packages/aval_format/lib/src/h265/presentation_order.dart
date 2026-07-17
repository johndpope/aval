/// HEVC picture-order-count derivation and unit-local presentation ordering.
///
/// Dart port of `packages/format/src/h265/presentation-order.ts`.
library;

import 'annex_b.dart' show isH265IdrNalType, isH265RandomAccessNalType;
import 'failure.dart';

/// Mutable per-unit POC derivation state.
///
/// Port of `H265PictureOrderState` (`src/h265/presentation-order.ts:7`).
class H265PictureOrderState {
  H265PictureOrderState({
    required this.initialized,
    required this.previousTid0PictureOrderCountLsb,
    required this.previousTid0PictureOrderCountMsb,
  });

  bool initialized;
  int previousTid0PictureOrderCountLsb;
  int previousTid0PictureOrderCountMsb;
}

/// Port of `H265DecodedPictureOrder` (`src/h265/presentation-order.ts:13`).
class H265DecodedPictureOrder {
  const H265DecodedPictureOrder({
    required this.decodeIndex,
    required this.pictureOrderCount,
  });

  final int decodeIndex;
  final int pictureOrderCount;
}

/// Port of `createH265PictureOrderState`
/// (`src/h265/presentation-order.ts:18`).
H265PictureOrderState createH265PictureOrderState() {
  return H265PictureOrderState(
    initialized: false,
    previousTid0PictureOrderCountLsb: 0,
    previousTid0PictureOrderCountMsb: 0,
  );
}

/// Derives PicOrderCntVal with unit-local state (HEVC 8.3.1 subset).
///
/// Port of `deriveH265PictureOrderCount`
/// (`src/h265/presentation-order.ts:27`).
int deriveH265PictureOrderCount(
  int nalType,
  int temporalId,
  int pictureOrderCountLsb,
  int log2MaxPictureOrderCountLsb,
  H265PictureOrderState state,
) {
  final maximum = 1 << log2MaxPictureOrderCountLsb;
  requireH265(
    pictureOrderCountLsb >= 0 && pictureOrderCountLsb < maximum,
    'pictureOrderCount',
    'slice picture-order-count LSB is out of range',
  );
  if (isH265IdrNalType(nalType)) {
    state.initialized = true;
    state.previousTid0PictureOrderCountLsb = 0;
    state.previousTid0PictureOrderCountMsb = 0;
    return 0;
  }
  var msb = 0;
  if (state.initialized && !isH265RandomAccessNalType(nalType)) {
    final previousLsb = state.previousTid0PictureOrderCountLsb;
    final previousMsb = state.previousTid0PictureOrderCountMsb;
    if (pictureOrderCountLsb < previousLsb &&
        previousLsb - pictureOrderCountLsb >= maximum / 2) {
      msb = previousMsb + maximum;
    } else if (pictureOrderCountLsb > previousLsb &&
        pictureOrderCountLsb - previousLsb > maximum / 2) {
      msb = previousMsb - maximum;
    } else {
      msb = previousMsb;
    }
  }
  final pictureOrderCount = msb + pictureOrderCountLsb;
  // RADL/RASL pictures (types 6..9) do not become prevTid0Pic.
  if (temporalId == 0 && !(nalType >= 6 && nalType <= 9)) {
    state.initialized = true;
    state.previousTid0PictureOrderCountLsb = pictureOrderCountLsb;
    state.previousTid0PictureOrderCountMsb = msb;
  }
  return pictureOrderCount;
}

/// Maps decoder submission order to a contiguous unit-local display order.
///
/// Port of `deriveH265PresentationOrder`
/// (`src/h265/presentation-order.ts:74`).
List<int> deriveH265PresentationOrder(
  List<H265DecodedPictureOrder> pictures,
  int maximumReorderPictures,
  String path,
) {
  requireH265(pictures.isNotEmpty, path, 'unit contains no decoded pictures');
  final sorted = List<H265DecodedPictureOrder>.from(pictures)
    ..sort((left, right) => left.pictureOrderCount - right.pictureOrderCount);
  final first = sorted[0].pictureOrderCount;
  final decodeToPresentation = List<int?>.filled(pictures.length, null);
  for (var presentationIndex = 0;
      presentationIndex < sorted.length;
      presentationIndex += 1) {
    final picture = sorted[presentationIndex];
    requireH265(
      picture.pictureOrderCount == first + presentationIndex,
      path,
      'unit picture-order counts must be unique and contiguous',
    );
    requireH265(
      picture.decodeIndex >= 0 &&
          picture.decodeIndex < pictures.length &&
          decodeToPresentation[picture.decodeIndex] == null,
      path,
      'unit decode index is duplicated or out of range',
    );
    decodeToPresentation[picture.decodeIndex] = presentationIndex;
  }
  var requiredReorder = 0;
  for (var decodeIndex = 0;
      decodeIndex < decodeToPresentation.length;
      decodeIndex += 1) {
    final presentationIndex = decodeToPresentation[decodeIndex];
    requireH265(presentationIndex != null, path, 'decode order has a gap');
    final delta = decodeIndex - presentationIndex!;
    requiredReorder = requiredReorder > delta ? requiredReorder : delta;
  }
  requireH265(
    requiredReorder <= maximumReorderPictures,
    path,
    'derived presentation reordering exceeds the SPS declaration',
  );
  return List.unmodifiable(decodeToPresentation.cast<int>());
}
