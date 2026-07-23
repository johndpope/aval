import {
  FORMAT_DEFAULT_BUDGETS,
  VIDEO_CODECS
} from "@pixel-point/aval-format";

import type {
  Av1Encoding,
  Canvas,
  H264Encoding,
  H264EncoderPreset,
  H265Encoding,
  NormalizedSourceRenditionTarget,
  NormalizedVideoEncoding,
  SourceRenditionTarget,
  VideoCodec,
  Vp9Encoding
} from "../model.js";
import {
  H264_ENCODER_PRESETS,
  H264_HW_ACCELERATORS,
  H265_ENCODER_PRESETS,
  VP9_DEADLINES
} from "../model.js";
import {
  boundedArray,
  exactKeys,
  identifier,
  integer,
  invalid,
  literal,
  oneOf,
  record
} from "../schema-validation.js";

/** Validate and normalize the ordered codec-major encoding list. */
export function cloneVideoEncodings(
  value: unknown,
  canvas: Readonly<Canvas>
): readonly NormalizedVideoEncoding[] {
  return cloneEncodingSet(value, canvas);
}

/** Validate and detach an already dimension-normalized encoding set. */
export function cloneNormalizedVideoEncodings(
  value: unknown
): readonly NormalizedVideoEncoding[] {
  return cloneEncodingSet(value, undefined);
}

function cloneEncodingSet(
  value: unknown,
  canvas: Readonly<Canvas> | undefined
): readonly NormalizedVideoEncoding[] {
  const inputs = boundedArray(value, "encodings", 1, VIDEO_CODECS.length);
  const seen = new Set<VideoCodec>();
  const encodings = inputs.map((entry, index) => {
    const path = `encodings[${String(index)}]`;
    const input = record(entry, path);
    const codec = oneOf(input.codec, VIDEO_CODECS, `${path}.codec`);
    if (seen.has(codec)) invalid(`${path}.codec`, `duplicates codec ${codec}`);
    seen.add(codec);
    switch (codec) {
      case "h264":
        return cloneH264Encoding(input, path, canvas);
      case "h265":
        return cloneH265Encoding(input, path, canvas);
      case "vp9":
        return cloneVp9Encoding(input, path, canvas);
      case "av1":
        return cloneAv1Encoding(input, path, canvas);
    }
  });
  return Object.freeze(encodings);
}

/**
 * Map libx264's 10-step preset scale (`ultrafast`..`placebo`) onto NVENC's
 * 7-step `p1` (fastest) .. `p7` (slowest/highest-quality) preset scale.
 *
 * This is a documented judgment call, not a precision mapping: NVENC's
 * presets trade off encode speed vs. quality along a materially different
 * curve than libx264's software presets, so there is no exact equivalence.
 * Chosen mapping (two adjacent libx264 presets collapse onto each faster
 * NVENC step, since NVENC only has 7 steps to libx264's 10):
 *   ultrafast, superfast -> p1
 *   veryfast,  faster    -> p2
 *   fast                 -> p3
 *   medium                -> p4 (NVENC's own documented default)
 *   slow                  -> p5
 *   slower                -> p6
 *   veryslow,  placebo    -> p7
 */
const NVENC_H264_PRESET_MAP: Readonly<Record<H264EncoderPreset, string>> =
  Object.freeze({
    ultrafast: "p1",
    superfast: "p1",
    veryfast: "p2",
    faster: "p2",
    fast: "p3",
    medium: "p4",
    slow: "p5",
    slower: "p6",
    veryslow: "p7",
    placebo: "p7"
  });

/** Lower only the allowlisted compression controls owned by an encoding. */
export function videoCompressionArguments(
  encoding: Readonly<NormalizedVideoEncoding>,
  rendition: Readonly<NormalizedSourceRenditionTarget>
): readonly string[] {
  const crf = ["-crf", String(rendition.crf)];
  switch (encoding.codec) {
    case "h264":
      if (encoding.hwAccel === "nvenc") {
        // NVENC has no CRF control; `-cq` is its constant-quality knob on
        // (approximately) the same 0-51 numeric scale as libx264's CRF, so
        // this is a direct passthrough of the rendition's existing CRF
        // value, NOT a calibrated perceptual match — libx264 CRF and NVENC
        // CQ ride different rate-distortion curves at the same number.
        // JUDGMENT CALL: ship this as the starting point, but visually
        // verify against the libx264 output at the same nominal value
        // before treating it as an equivalent quality bar.
        // `-b:v 0` paired with `-rc vbr` leaves bitrate unconstrained so CQ
        // alone drives quality, mirroring CRF's "no explicit bitrate" model.
        return Object.freeze([
          "-preset", NVENC_H264_PRESET_MAP[encoding.preset],
          "-tune", "hq",
          "-rc", "vbr",
          "-cq", String(rendition.crf),
          "-b:v", "0"
        ]);
      }
      return Object.freeze([...crf, "-preset", encoding.preset]);
    case "h265":
      return Object.freeze([
        ...crf,
        "-preset", encoding.preset,
        "-threads", String(encoding.threads)
      ]);
    case "vp9":
      return Object.freeze([
        ...crf,
        "-b:v", "0",
        "-deadline", encoding.deadline,
        "-cpu-used", String(encoding.cpuUsed),
        "-threads", String(encoding.threads)
      ]);
    case "av1":
      return Object.freeze([
        ...crf,
        "-b:v", "0",
        "-pix_fmt", encoding.bitDepth === 10 ? "yuv420p10le" : "yuv420p",
        "-cpu-used", String(encoding.cpuUsed),
        "-tiles", `${String(encoding.tiles.columns)}x${String(encoding.tiles.rows)}`,
        "-row-mt", encoding.rowMt ? "1" : "0",
        "-threads", String(encoding.threads)
      ]);
  }
}

function cloneH264Encoding(
  input: Record<string, unknown>,
  path: string,
  canvas: Readonly<Canvas> | undefined
): H264Encoding<NormalizedSourceRenditionTarget> {
  exactKeys(input, ["codec", "preset", "renditions"], path, ["hwAccel"]);
  return Object.freeze({
    codec: literal(input.codec, "h264", `${path}.codec`),
    preset: oneOf(input.preset, H264_ENCODER_PRESETS, `${path}.preset`),
    ...(input.hwAccel === undefined
      ? {}
      : {
          hwAccel: oneOf(input.hwAccel, H264_HW_ACCELERATORS, `${path}.hwAccel`)
        }),
    renditions: cloneRenditions(input.renditions, path, canvas, 51)
  });
}

function cloneH265Encoding(
  input: Record<string, unknown>,
  path: string,
  canvas: Readonly<Canvas> | undefined
): H265Encoding<NormalizedSourceRenditionTarget> {
  exactKeys(input, ["codec", "preset", "threads", "renditions"], path);
  return Object.freeze({
    codec: literal(input.codec, "h265", `${path}.codec`),
    preset: oneOf(input.preset, H265_ENCODER_PRESETS, `${path}.preset`),
    threads: integer(input.threads, `${path}.threads`, 1, 64),
    renditions: cloneRenditions(input.renditions, path, canvas, 51)
  });
}

function cloneVp9Encoding(
  input: Record<string, unknown>,
  path: string,
  canvas: Readonly<Canvas> | undefined
): Vp9Encoding<NormalizedSourceRenditionTarget> {
  exactKeys(
    input,
    ["codec", "deadline", "cpuUsed", "threads", "renditions"],
    path
  );
  return Object.freeze({
    codec: literal(input.codec, "vp9", `${path}.codec`),
    deadline: oneOf(input.deadline, VP9_DEADLINES, `${path}.deadline`),
    cpuUsed: integer(input.cpuUsed, `${path}.cpuUsed`, -8, 8),
    threads: integer(input.threads, `${path}.threads`, 1, 64),
    renditions: cloneRenditions(input.renditions, path, canvas, 63)
  });
}

function cloneAv1Encoding(
  input: Record<string, unknown>,
  path: string,
  canvas: Readonly<Canvas> | undefined
): Av1Encoding<NormalizedSourceRenditionTarget> {
  exactKeys(
    input,
    [
      "codec", "bitDepth", "cpuUsed", "tiles", "rowMt", "threads",
      "renditions"
    ],
    path
  );
  const tilesInput = record(input.tiles, `${path}.tiles`);
  exactKeys(tilesInput, ["columns", "rows"], `${path}.tiles`);
  const columns = tileDimension(tilesInput.columns, `${path}.tiles.columns`);
  const rows = tileDimension(tilesInput.rows, `${path}.tiles.rows`);
  if (columns * rows > 64) {
    invalid(`${path}.tiles`, "tile product must be at most 64");
  }
  return Object.freeze({
    codec: literal(input.codec, "av1", `${path}.codec`),
    bitDepth: bitDepth(input.bitDepth, `${path}.bitDepth`),
    cpuUsed: integer(input.cpuUsed, `${path}.cpuUsed`, 0, 8),
    tiles: Object.freeze({ columns, rows }),
    rowMt: boolean(input.rowMt, `${path}.rowMt`),
    threads: integer(input.threads, `${path}.threads`, 1, 64),
    renditions: cloneRenditions(input.renditions, path, canvas, 63)
  });
}

function cloneRenditions(
  value: unknown,
  encodingPath: string,
  canvas: Readonly<Canvas> | undefined,
  maximumCrf: number
): readonly NormalizedSourceRenditionTarget[] {
  const inputs = boundedArray(
    value,
    `${encodingPath}.renditions`,
    1,
    FORMAT_DEFAULT_BUDGETS.maxRenditions
  );
  const seen = new Set<string>();
  const renditions = inputs.map((entry, index) => {
    const path = `${encodingPath}.renditions[${String(index)}]`;
    const input = record(entry, path);
    exactKeys(input, ["id", "width", "height", "crf"], path);
    const id = identifier(input.id, `${path}.id`);
    if (seen.has(id)) invalid(`${path}.id`, `duplicates id ${id}`);
    seen.add(id);
    const crf = integer(input.crf, `${path}.crf`, 0, maximumCrf);
    if (canvas === undefined) {
      return Object.freeze({
        id,
        width: integer(input.width, `${path}.width`, 1, 0xffff_ffff),
        height: integer(input.height, `${path}.height`, 1, 0xffff_ffff),
        crf
      });
    }
    return normalizeRendition(Object.freeze({
      id,
      width: dimension(input.width, `${path}.width`, canvas.width),
      height: dimension(input.height, `${path}.height`, canvas.height),
      crf
    }), path, canvas);
  });
  return Object.freeze(renditions);
}

function normalizeRendition(
  target: Readonly<SourceRenditionTarget>,
  path: string,
  canvas: Readonly<Canvas>
): NormalizedSourceRenditionTarget {
  if (target.width === "auto" && target.height === "auto") {
    invalid(path, "width and height cannot both be auto");
  }
  if (target.width !== "auto" && target.height !== "auto") {
    if (
      BigInt(target.width) * BigInt(canvas.height) !==
      BigInt(target.height) * BigInt(canvas.width)
    ) {
      invalid(path, "explicit dimensions must preserve the canvas aspect ratio");
    }
    return Object.freeze({ ...target, width: target.width, height: target.height });
  }
  if (target.width === "auto") {
    const width = evenScaledDimension(
      target.height as number,
      canvas.width,
      canvas.height,
      `${path}.width`
    );
    if (width > canvas.width) invalid(`${path}.width`, "exceeds canvas width");
    return Object.freeze({ ...target, width, height: target.height as number });
  }
  const height = evenScaledDimension(
    target.width,
    canvas.height,
    canvas.width,
    `${path}.height`
  );
  if (height > canvas.height) invalid(`${path}.height`, "exceeds canvas height");
  return Object.freeze({ ...target, width: target.width, height });
}

function evenScaledDimension(
  fixedDimension: number,
  targetAxis: number,
  fixedAxis: number,
  path: string
): number {
  const numerator = BigInt(fixedDimension) * BigInt(targetAxis);
  const denominator = BigInt(fixedAxis);
  const roundedUnits = (numerator + denominator) / (2n * denominator);
  const result = roundedUnits * 2n;
  if (result < 2n || result > BigInt(Number.MAX_SAFE_INTEGER)) {
    invalid(path, "cannot be resolved to a positive even safe integer");
  }
  return Number(result);
}

function dimension(
  value: unknown,
  path: string,
  maximum: number
): number | "auto" {
  return value === "auto" ? "auto" : integer(value, path, 1, maximum);
}

function tileDimension(value: unknown, path: string): number {
  const result = integer(value, path, 1, 64);
  if ((result & (result - 1)) !== 0) invalid(path, "must be a power of two");
  return result;
}

function bitDepth(value: unknown, path: string): 8 | 10 {
  if (value !== 8 && value !== 10) invalid(path, "must be 8 or 10");
  return value;
}

function boolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") invalid(path, "must be a boolean");
  return value;
}
