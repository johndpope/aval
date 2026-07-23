import { dirname } from "node:path";

import type {
  VideoRenditionGeometry
} from "@pixel-point/aval-format";
import type {
  NormalizedSourceRenditionTarget,
  NormalizedVideoEncoding,
  Rational,
  VideoCodec
} from "../model.js";
import {
  MAX_PROCESS_OUTPUT_BYTES,
  MAX_PROCESS_STDERR_BYTES
} from "../model.js";
import { videoCompressionArguments } from "../compile/video-encoding-policy.js";
import { CompilerError } from "../diagnostics.js";
import { runBoundedProcess } from "../process-runner.js";
import { parseIvf, type IvfFrame } from "./ivf.js";

export interface RawYuv420FrameSource {
  readonly path: string;
  readonly width: number;
  readonly height: number;
  readonly bitDepth: 8 | 10;
  readonly frameRate: Rational;
  readonly frameBytes: number;
}

export interface EncodeVideoUnitInput {
  readonly source: Readonly<RawYuv420FrameSource>;
  readonly startFrame: number;
  readonly endFrame: number;
  readonly encoding: Readonly<NormalizedVideoEncoding>;
  readonly rendition: Readonly<NormalizedSourceRenditionTarget>;
  readonly geometry: Readonly<VideoRenditionGeometry>;
}

export interface EncodeVideoUnitInvocation {
  readonly arguments: readonly string[];
  readonly cwd: string;
  readonly stdinFile: {
    readonly path: string;
    readonly offset: number;
    readonly length: number;
  };
}

export interface EncodeIvfVideoUnitInput extends EncodeVideoUnitInput {
  readonly encoding: Extract<NormalizedVideoEncoding, { readonly codec: "vp9" | "av1" }>;
  readonly executable?: string;
  readonly signal?: AbortSignal;
  /** Optional positive subprocess wall limit. No timeout is applied when absent. */
  readonly timeoutMs?: number;
  readonly maximumOutputBytes?: number;
}

export interface EncodeElementaryVideoUnitInput extends EncodeVideoUnitInput {
  readonly encoding: Extract<NormalizedVideoEncoding, { readonly codec: "h264" | "h265" }>;
  readonly executable?: string;
  readonly signal?: AbortSignal;
  /** Optional positive subprocess wall limit. No timeout is applied when absent. */
  readonly timeoutMs?: number;
  readonly maximumOutputBytes?: number;
}

export interface EncodedIvfVideoUnit {
  readonly codec: "vp9" | "av1";
  readonly timeBase: {
    readonly numerator: number;
    readonly denominator: number;
  };
  /** IVF record order is decoder submission order; IVF headers are discarded. */
  readonly packets: readonly IvfFrame[];
}

/** Encode one H.264/H.265 closed unit as a bounded elementary stream. */
export async function encodeElementaryVideoUnit(
  input: Readonly<EncodeElementaryVideoUnitInput>
): Promise<Uint8Array> {
  const invocation = createEncodeVideoUnitInvocation(input);
  const maximumOutputBytes = outputBudget(
    input,
    input.endFrame - input.startFrame
  );
  const result = await runBoundedProcess({
    executable: input.executable ?? "ffmpeg",
    arguments: invocation.arguments,
    cwd: invocation.cwd,
    stdinFile: invocation.stdinFile,
    limits: {
      maxStdoutBytes: maximumOutputBytes,
      maxStderrBytes: MAX_PROCESS_STDERR_BYTES,
      ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs })
    },
    privateWorkingDirectory: true,
    ...(input.signal === undefined ? {} : { signal: input.signal })
  });
  if (result.stdout.byteLength < 1) {
    throw new CompilerError(
      "FFMPEG_FAILED",
      `FFmpeg emitted an empty ${input.encoding.codec} elementary unit`,
      { phase: "encode" }
    );
  }
  return result.stdout;
}

/** Encode VP9/AV1 and strip the bounded IVF stdout transport immediately. */
export async function encodeIvfVideoUnit(
  input: Readonly<EncodeIvfVideoUnitInput>
): Promise<Readonly<EncodedIvfVideoUnit>> {
  const invocation = createEncodeVideoUnitInvocation(input);
  const frameCount = input.endFrame - input.startFrame;
  const maximumOutputBytes = outputBudget(input, frameCount);
  const result = await runBoundedProcess({
    executable: input.executable ?? "ffmpeg",
    arguments: invocation.arguments,
    cwd: invocation.cwd,
    stdinFile: invocation.stdinFile,
    limits: {
      maxStdoutBytes: maximumOutputBytes,
      maxStderrBytes: MAX_PROCESS_STDERR_BYTES,
      ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs })
    },
    privateWorkingDirectory: true,
    ...(input.signal === undefined ? {} : { signal: input.signal })
  });
  const parsed = parseIvf(result.stdout, {
    expectedCodec: input.encoding.codec,
    expectedWidth: input.source.width,
    expectedHeight: input.source.height,
    maximumFrames: checkedProduct(frameCount, 4, "IVF frame budget"),
    maximumFrameBytes: maximumOutputBytes
  });
  if (
    parsed.timeBase.numerator * input.source.frameRate.numerator !==
    parsed.timeBase.denominator * input.source.frameRate.denominator
  ) {
    throw new CompilerError(
      "FFMPEG_FAILED",
      "IVF time base does not match the requested frame rate",
      { phase: "encode" }
    );
  }
  return Object.freeze({
    codec: parsed.codec,
    timeBase: parsed.timeBase,
    packets: parsed.frames
  });
}

/** Create the exact shell-free FFmpeg invocation for one closed graph unit. */
export function createEncodeVideoUnitInvocation(
  input: Readonly<EncodeVideoUnitInput>
): Readonly<EncodeVideoUnitInvocation> {
  const frameCount = validate(input);
  const sourcePixelFormat = input.source.bitDepth === 10
    ? "yuv420p10le"
    : "yuv420p";
  const arguments_ = Object.freeze([
    "-nostdin",
    "-hide_banner",
    "-loglevel", "error",
    "-xerror",
    "-protocol_whitelist", "pipe",
    "-f", "rawvideo",
    "-pixel_format", sourcePixelFormat,
    "-video_size", `${String(input.source.width)}x${String(input.source.height)}`,
    "-framerate",
    `${String(input.source.frameRate.numerator)}/${String(input.source.frameRate.denominator)}`,
    "-i", "pipe:0",
    "-map", "0:v:0",
    "-an", "-sn", "-dn",
    "-map_metadata", "-1",
    "-map_chapters", "-1",
    "-frames:v", String(frameCount),
    "-fps_mode", "passthrough",
    "-c:v", encoder(input.encoding),
    ...videoCompressionArguments(input.encoding, input.rendition),
    ...(input.encoding.codec === "av1" ? [] : ["-pix_fmt", "yuv420p"]),
    "-color_range", "tv",
    "-color_primaries", "bt709",
    "-color_trc", "bt709",
    "-colorspace", "bt709",
    "-g", String(frameCount),
    "-keyint_min", String(frameCount),
    "-sc_threshold", "0",
    ...codecArguments(input.encoding, frameCount, input.geometry),
    "-f", outputFormat(input.encoding.codec),
    "pipe:1"
  ]);
  const offset = checkedProduct(input.startFrame, input.source.frameBytes, "unit byte offset");
  const length = checkedProduct(frameCount, input.source.frameBytes, "unit byte length");
  return Object.freeze({
    arguments: arguments_,
    cwd: dirname(input.source.path),
    stdinFile: Object.freeze({ path: input.source.path, offset, length })
  });
}

function validate(input: Readonly<EncodeVideoUnitInput>): number {
  if (typeof input !== "object" || input === null) {
    throw invalid("Video encode input must be an object");
  }
  const { source, encoding, rendition } = input;
  if (typeof source !== "object" || source === null) {
    throw invalid("Video encode source must be an object");
  }
  if (typeof source.path !== "string" || source.path.length === 0) {
    throw invalid("Video encode source path must be nonempty");
  }
  for (const [label, value] of [
    ["width", source.width],
    ["height", source.height],
    ["frame-rate numerator", source.frameRate?.numerator],
    ["frame-rate denominator", source.frameRate?.denominator]
  ] as const) {
    if (!Number.isSafeInteger(value) || value < 1) {
      throw invalid(`Video encode ${label} must be a positive safe integer`);
    }
  }
  if (source.width % 2 !== 0 || source.height % 2 !== 0) {
    throw invalid("Video encode dimensions must be even for YUV420");
  }
  if (typeof rendition !== "object" || rendition === null) {
    throw invalid("Video encode rendition must be an object");
  }
  const geometry = input.geometry;
  if (
    typeof geometry !== "object" ||
    geometry === null ||
    geometry.codedWidth !== source.width ||
    geometry.codedHeight !== source.height ||
    geometry.visibleColorRect[2] !== rendition.width ||
    geometry.visibleColorRect[3] !== rendition.height
  ) {
    throw invalid("Video encode source and visible dimensions must match the shared geometry");
  }
  if (typeof encoding !== "object" || encoding === null) {
    throw invalid("Video encoding policy must be an object");
  }
  const expectedBitDepth = encoding.codec === "av1" ? encoding.bitDepth : 8;
  if (source.bitDepth !== expectedBitDepth) {
    throw invalid("Video source bit depth does not match the codec policy");
  }
  const policyRendition = encoding.renditions.find((candidate) => candidate.id === rendition.id);
  if (
    policyRendition === undefined ||
    policyRendition.width !== rendition.width ||
    policyRendition.height !== rendition.height ||
    policyRendition.crf !== rendition.crf
  ) {
    throw invalid("Video rendition is not owned by the codec policy");
  }
  const bytesPerSample = source.bitDepth === 10 ? 2 : 1;
  const expectedFrameBytes = checkedProduct(
    checkedProduct(source.width, source.height, "YUV frame pixels"),
    3,
    "YUV frame components"
  ) / 2 * bytesPerSample;
  if (!Number.isSafeInteger(expectedFrameBytes) || source.frameBytes !== expectedFrameBytes) {
    throw invalid("Video source frame byte count does not match its dimensions and bit depth");
  }
  if (
    !Number.isSafeInteger(input.startFrame) ||
    !Number.isSafeInteger(input.endFrame) ||
    input.startFrame < 0 ||
    input.endFrame <= input.startFrame
  ) {
    throw invalid("Video unit frame range must be nonempty, nonnegative, and half-open");
  }
  return input.endFrame - input.startFrame;
}

function encoder(encoding: Readonly<NormalizedVideoEncoding>): string {
  switch (encoding.codec) {
    // hwAccel is opt-in and additive; absent (the default) keeps the
    // existing libx264 path byte-identical.
    case "h264": return encoding.hwAccel === "nvenc" ? "h264_nvenc" : "libx264";
    case "h265": return "libx265";
    case "vp9": return "libvpx-vp9";
    case "av1": return "libaom-av1";
  }
}

function outputFormat(codec: VideoCodec): "h264" | "hevc" | "ivf" {
  switch (codec) {
    case "h264": return "h264";
    case "h265": return "hevc";
    case "vp9":
    case "av1":
      return "ivf";
  }
}

function codecArguments(
  encoding: Readonly<NormalizedVideoEncoding>,
  frameCount: number,
  geometry: Readonly<VideoRenditionGeometry>
): readonly string[] {
  switch (encoding.codec) {
    case "h264": {
      // Validate the crop deltas the same way for both encoder backends —
      // NVENC branches off this same geometry guard below instead of
      // duplicating it.
      const cropRect = h264CropRect(geometry);
      if (encoding.hwAccel === "nvenc") {
        return nvencH264Arguments(geometry);
      }
      return [
        "-profile:v", "high",
        "-x264-params",
        [
          "8x8dct=1",
          "aud=1",
          "cabac=1",
          "colorprim=bt709",
          "colormatrix=bt709",
          `crop-rect=${cropRect.join(",")}`,
          "force-cfr=1",
          `keyint=${String(frameCount)}`,
          `min-keyint=${String(frameCount)}`,
          "open-gop=0",
          "range=tv",
          "repeat-headers=1",
          "scenecut=0",
          "transfer=bt709"
        ].join(":")
      ];
    }
    case "h265":
      return [
        "-profile:v", "main",
        "-x265-params",
        [
          "aud=1",
          "colorprim=bt709",
          "colormatrix=bt709",
          `keyint=${String(frameCount)}`,
          `min-keyint=${String(frameCount)}`,
          "open-gop=0",
          "range=limited",
          "repeat-headers=1",
          "scenecut=0",
          "transfer=bt709"
        ].join(":")
      ];
    case "vp9":
      return [];
    case "av1":
      // FFmpeg's generic color options do not populate libaom's sequence-header
      // CICP fields; pass the encoder-owned controls as well.
      return [
        "-aom-params",
        "color-primaries=1:transfer-characteristics=1:matrix-coefficients=1"
      ];
  }
}

/**
 * NVENC-equivalent H.264 codec arguments. `h264_nvenc` accepts none of
 * libx264's `-x264-params`, so every guarantee that block carried has to be
 * re-derived here, one clause at a time:
 *
 * - `crop-rect=...` (SPS conformance-window crop) is a REAL pixel-geometry
 *   requirement, not cosmetic SEI: this repo's own test for it is titled
 *   "owns packed H.264 macroblock padding and the matching SPS crop"
 *   (packages/compiler/test/video-encode-unit.test.ts). H.264 alone among
 *   the four codecs stores at 16x16 macroblock alignment (see
 *   MACROBLOCK_ALIGNMENT in compile/video-codec-compiler.ts; every other
 *   codec only needs 2x2 YUV420 alignment and never needed a crop), so the
 *   raw rawvideo pipe:0 input handed to the encoder is macroblock-padded
 *   beyond geometry.decodedStorageRect. Reproducing this with `-x264-params
 *   crop-rect=` is not an option for NVENC, so instead a pre-encode
 *   `-vf crop=...` filter trims the input down to the exact
 *   decodedStorageRect pane before NVENC ever sees it. NVENC then handles
 *   its own internal macroblock alignment and emits the correct SPS
 *   conformance window automatically — unlike libx264, it does not require
 *   the caller to hand-manage mod-16 padding once the input is already the
 *   pane size.
 * - `aud=1` is NOT cosmetic either: the format's own access-unit normalizer
 *   (packages/format/src/h264/encoder-preparation.ts) hard-requires every
 *   access unit to begin with an AUD NAL ("normalized access unit must
 *   begin with AUD") because these are raw elementary streams with no
 *   container framing. `-aud 1` reproduces this for NVENC.
 * - `colorprim`/`colormatrix`/`transfer`/`range` in the libx264 params are
 *   pure belt-and-suspenders duplicates of the generic
 *   `-color_range`/`-color_primaries`/`-color_trc`/`-colorspace` flags set
 *   unconditionally above in createEncodeVideoUnitInvocation — FFmpeg's
 *   libx264 wrapper forwards those AVCodecContext fields into libx264's VUI
 *   automatically, and its NVENC wrapper does the same. No NVENC-specific
 *   color flags are needed.
 * - `force-cfr=1` is likewise redundant here: the input is already
 *   perfectly constant-frame-rate (a `-f rawvideo` pipe with an explicit
 *   `-framerate` and `-fps_mode passthrough`, so there are no source
 *   timestamps to normalize). No NVENC equivalent is needed.
 * - `8x8dct=1`/`cabac=1` are High-profile defaults; NVENC uses the 8x8
 *   transform for High profile automatically (no separate FFmpeg option
 *   exists for it), and `-coder cabac` pins CABAC explicitly rather than
 *   leaving it to NVENC's own profile-dependent default.
 * - Closed GOP / no mid-unit keyframes (`scenecut=0`, `open-gop=0`,
 *   `keyint=`/`min-keyint=` matching frameCount) map to `-no-scenecut 1`
 *   (disable scene-cut-triggered keyframe insertion), `-strict_gop 1`
 *   (don't let NVENC vary GOP structure away from the generic `-g
 *   frameCount -keyint_min frameCount -sc_threshold 0` already set
 *   unconditionally above), `-forced-idr 1` (force the one keyframe this
 *   unit does emit to be a true IDR, not an I-frame carrying open-GOP-style
 *   forward references), and `-rc-lookahead 0` (rate-control lookahead can
 *   otherwise choose to insert its own keyframes; disabling it removes that
 *   path entirely).
 *
 * JUDGMENT CALL: these flag names/semantics are the well-documented FFmpeg
 * h264_nvenc AVOptions as of recent FFmpeg/NVENC SDK releases, but NVENC
 * option names have shifted across FFmpeg versions historically. Confirm
 * against the exact ffmpeg build on the target GPU box
 * (`ffmpeg -h encoder=h264_nvenc`) before relying on this in production.
 */
function nvencH264Arguments(
  geometry: Readonly<VideoRenditionGeometry>
): readonly string[] {
  const [left, top, width, height] = geometry.decodedStorageRect;
  return [
    "-vf", `crop=${String(width)}:${String(height)}:${String(left)}:${String(top)}`,
    "-profile:v", "high",
    "-coder", "cabac",
    "-aud", "1",
    "-no-scenecut", "1",
    "-strict_gop", "1",
    "-forced-idr", "1",
    "-rc-lookahead", "0"
  ];
}

function h264CropRect(
  geometry: Readonly<VideoRenditionGeometry>
): readonly [number, number, number, number] {
  const [left, top, decodedWidth, decodedHeight] = geometry.decodedStorageRect;
  const crop = [
    left,
    top,
    geometry.codedWidth - left - decodedWidth,
    geometry.codedHeight - top - decodedHeight
  ] as const;
  if (crop.some((value) =>
    !Number.isSafeInteger(value) || value < 0 || value % 2 !== 0
  )) {
    throw invalid("H.264 crop deltas must be nonnegative even safe integers");
  }
  return crop;
}

function outputBudget(
  input: Readonly<EncodeVideoUnitInput & { readonly maximumOutputBytes?: number }>,
  frameCount: number
): number {
  if (input.maximumOutputBytes !== undefined) {
    if (!Number.isSafeInteger(input.maximumOutputBytes) || input.maximumOutputBytes < 1) {
      throw invalid("Maximum encoded output bytes must be a positive safe integer");
    }
    return Math.min(input.maximumOutputBytes, MAX_PROCESS_OUTPUT_BYTES);
  }
  const rawBytes = checkedProduct(frameCount, input.source.frameBytes, "raw unit byte length");
  const doubled = checkedProduct(rawBytes, 2, "encoded output budget");
  const withOverhead = doubled + 1024 * 1024;
  if (!Number.isSafeInteger(withOverhead)) {
    throw invalid("Encoded output budget exceeds the safe integer range");
  }
  return Math.min(MAX_PROCESS_OUTPUT_BYTES, Math.max(1024 * 1024, withOverhead));
}

function checkedProduct(left: number, right: number, label: string): number {
  const result = left * right;
  if (!Number.isSafeInteger(result) || result < 0) {
    throw invalid(`${label} exceeds the safe integer range`);
  }
  return result;
}

function invalid(message: string): CompilerError {
  return new CompilerError("INPUT_INVALID", message, { phase: "encode" });
}
