import type { VideoBitDepth, VideoCodec } from "../model.js";

const H264 = /^avc1\.[0-9A-F]{6}$/;
const H265 = /^hvc1\.[ABC]?\d+\.[0-9A-F]+\.[LH]\d+(?:\.[0-9A-F]{2}){1,6}$/;
const VP9 = /^vp09\.(\d{2})\.(\d{2})\.(08|10|12)(?:\.\d{2}\.\d{2}\.\d{2}\.\d{2}\.\d{2})?$/;
const AV1 = /^av01\.[0-2]\.\d{2}[MH]\.(08|10|12)(?:\.\d\.\d{3}\.\d{2}\.\d{2}\.\d{2}\.\d)?$/;

export interface ParsedVideoCodecString {
  readonly family: VideoCodec;
  readonly bitDepth?: VideoBitDepth;
}

/** Parse one canonical, fully qualified WebCodecs codec string. */
export function parseVideoCodecString(
  value: string
): Readonly<ParsedVideoCodecString> | undefined {
  if (H264.test(value)) return Object.freeze({ family: "h264" });
  if (H265.test(value)) return Object.freeze({ family: "h265" });
  const vp9 = VP9.exec(value);
  if (vp9 !== null) {
    return Object.freeze({
      family: "vp9",
      bitDepth: Number(vp9[3]) as VideoBitDepth
    });
  }
  const av1 = AV1.exec(value);
  if (av1 !== null) {
    return Object.freeze({
      family: "av1",
      bitDepth: Number(av1[1]) as VideoBitDepth
    });
  }
  return undefined;
}

export function isVideoCodecString(
  value: unknown,
  family: VideoCodec,
  bitDepth: VideoBitDepth
): value is string {
  if (typeof value !== "string") return false;
  const parsed = parseVideoCodecString(value);
  return parsed?.family === family &&
    (parsed.bitDepth === undefined || parsed.bitDepth === bitDepth);
}
