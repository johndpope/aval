import type { Rect, VideoLayout } from "../model.js";

export interface VideoStoragePolicy {
  /** Required encoded-surface width multiple. */
  readonly widthAlignment: number;
  /** Required encoded-surface height multiple. */
  readonly heightAlignment: number;
}

export interface VideoRenditionGeometryInput {
  readonly canvasWidth: number;
  readonly canvasHeight: number;
  readonly layout: VideoLayout;
  readonly visibleWidth: number;
  readonly visibleHeight: number;
  readonly storage: VideoStoragePolicy;
}

export interface VideoRenditionGeometry {
  readonly layout: VideoLayout;
  readonly visibleColorRect: Rect;
  readonly visibleAlphaRect?: Rect;
  readonly decodedStorageRect: Rect;
  readonly codedWidth: number;
  readonly codedHeight: number;
  readonly visibleColorArea: number;
  readonly decodedRgbaBytes: number;
  readonly codedRgbaBytes: number;
}
