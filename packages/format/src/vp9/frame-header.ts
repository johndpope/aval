import { FormatError } from "../errors.js";
import { Vp9BitReader } from "./bit-reader.js";

const VP9_FRAME_MARKER = 2;
const VP9_SYNC_CODE = 0x49_83_42;
const VP9_COLOR_SPACE_BT709 = 2;

export interface Vp9ColorConfig {
  readonly bitDepth: 8;
  readonly chromaSubsampling: 1;
  readonly colorPrimaries: 1;
  readonly transferCharacteristics: 1;
  readonly matrixCoefficients: 1;
  readonly fullRange: false;
}

export interface Vp9FrameHeader {
  readonly profile: 0;
  readonly key: boolean;
  readonly showFrame: boolean;
  readonly showExistingFrame: boolean;
  readonly displayedFrameCount: 0 | 1;
  readonly errorResilient: boolean;
  readonly width?: number;
  readonly height?: number;
  readonly renderWidth?: number;
  readonly renderHeight?: number;
  readonly color?: Vp9ColorConfig;
}

/** Parse the bounded VP9 uncompressed header needed by the AVAL profile. */
export function parseVp9FrameHeader(
  bytes: Uint8Array,
  path = "vp9.frame"
): Readonly<Vp9FrameHeader> {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) {
    throw new FormatError("PROFILE_INVALID", "VP9 frame is empty", { path });
  }
  const reader = new Vp9BitReader(bytes, path);
  requireVp9(
    reader.readBits(2, "frame_marker") === VP9_FRAME_MARKER,
    path,
    "frame_marker must equal 2"
  );
  const profile = Number(reader.readBit("profile_low")) |
    (Number(reader.readBit("profile_high")) << 1);
  if (profile === 3) {
    requireVp9(!reader.readBit("reserved_zero"), path, "reserved profile bit must be zero");
  }
  requireVp9(profile === 0, path, "only 8-bit 4:2:0 profile 0 is supported");

  const showExistingFrame = reader.readBit("show_existing_frame");
  if (showExistingFrame) {
    reader.readBits(3, "frame_to_show_map_idx");
    return Object.freeze({
      profile: 0,
      key: false,
      showFrame: true,
      showExistingFrame: true,
      displayedFrameCount: 1,
      errorResilient: false
    });
  }

  const key = !reader.readBit("frame_type");
  const showFrame = reader.readBit("show_frame");
  const errorResilient = reader.readBit("error_resilient_mode");
  if (!key) {
    return Object.freeze({
      profile: 0,
      key,
      showFrame,
      showExistingFrame: false,
      displayedFrameCount: showFrame ? 1 : 0,
      errorResilient
    });
  }

  requireVp9(
    reader.readBits(24, "frame_sync_code") === VP9_SYNC_CODE,
    path,
    "key frame sync code is invalid"
  );
  const colorSpace = reader.readBits(3, "color_space");
  requireVp9(
    colorSpace === VP9_COLOR_SPACE_BT709,
    path,
    "key frame must signal BT.709 color space"
  );
  requireVp9(!reader.readBit("color_range"), path, "key frame must use limited range");

  const width = reader.readBits(16, "frame_width_minus_1") + 1;
  const height = reader.readBits(16, "frame_height_minus_1") + 1;
  requireVp9(width > 0 && height > 0, path, "key frame dimensions are invalid");
  const renderAndFrameSizeDifferent = reader.readBit("render_and_frame_size_different");
  const renderWidth = renderAndFrameSizeDifferent
    ? reader.readBits(16, "render_width_minus_1") + 1
    : width;
  const renderHeight = renderAndFrameSizeDifferent
    ? reader.readBits(16, "render_height_minus_1") + 1
    : height;

  return Object.freeze({
    profile: 0,
    key,
    showFrame,
    showExistingFrame: false,
    displayedFrameCount: showFrame ? 1 : 0,
    errorResilient,
    width,
    height,
    renderWidth,
    renderHeight,
    color: Object.freeze({
      bitDepth: 8,
      chromaSubsampling: 1,
      colorPrimaries: 1,
      transferCharacteristics: 1,
      matrixCoefficients: 1,
      fullRange: false
    })
  });
}

function requireVp9(
  condition: boolean,
  path: string,
  message: string
): asserts condition {
  if (!condition) {
    throw new FormatError("PROFILE_INVALID", `VP9 ${message}`, { path });
  }
}
