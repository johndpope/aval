/// Shared codec-agnostic video surface types.
///
/// Dart port of `packages/format/src/video/model.ts`.
library;

import '../model.dart' show Rect, VideoLayout;

/// Codec-owned encoded-surface alignment policy.
class VideoStoragePolicy {
  const VideoStoragePolicy({
    required this.widthAlignment,
    required this.heightAlignment,
  });

  /// Required encoded-surface width multiple.
  final int widthAlignment;

  /// Required encoded-surface height multiple.
  final int heightAlignment;
}

class VideoRenditionGeometryInput {
  const VideoRenditionGeometryInput({
    required this.canvasWidth,
    required this.canvasHeight,
    required this.layout,
    required this.visibleWidth,
    required this.visibleHeight,
    required this.storage,
  });

  final int canvasWidth;
  final int canvasHeight;
  final VideoLayout layout;
  final int visibleWidth;
  final int visibleHeight;
  final VideoStoragePolicy storage;
}

class VideoRenditionGeometry {
  const VideoRenditionGeometry({
    required this.layout,
    required this.visibleColorRect,
    this.visibleAlphaRect,
    required this.decodedStorageRect,
    required this.codedWidth,
    required this.codedHeight,
    required this.visibleColorArea,
    required this.decodedRgbaBytes,
    required this.codedRgbaBytes,
  });

  final VideoLayout layout;
  final Rect visibleColorRect;
  final Rect? visibleAlphaRect;
  final Rect decodedStorageRect;
  final int codedWidth;
  final int codedHeight;
  final int visibleColorArea;
  final int decodedRgbaBytes;
  final int codedRgbaBytes;
}
