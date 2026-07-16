import { requireH265 } from "./failure.js";
import type { H265ProfileTierLevel, ParsedH265Sps } from "./parameter-sets.js";
import type { H265VideoDecoderConfig } from "./types.js";

const PROFILE_SPACE_PREFIX = Object.freeze(["", "A", "B", "C"] as const);

/** Derives the RFC 6381/ISO BMFF HEVC identifier used by WebCodecs. */
export function h265CodecString(profileTierLevel: H265ProfileTierLevel): string {
  const prefix = PROFILE_SPACE_PREFIX[profileTierLevel.profileSpace];
  requireH265(prefix !== undefined, "profileTierLevel", "invalid profile space");
  const compatibility = profileTierLevel.profileCompatibilityFlags
    .toString(16)
    .toUpperCase();
  const constraints = [...profileTierLevel.constraintIndicatorFlags];
  while (constraints.at(-1) === 0) constraints.pop();
  const suffix = constraints
    .map((byte) => byte.toString(16).toUpperCase().padStart(2, "0"))
    .join(".");
  return `hvc1.${prefix}${String(profileTierLevel.profileIdc)}.${compatibility}.${
    profileTierLevel.tierFlag ? "H" : "L"
  }${String(profileTierLevel.levelIdc)}${suffix.length === 0 ? "" : `.${suffix}`}`;
}

export function createH265VideoDecoderConfig(
  sps: ParsedH265Sps
): H265VideoDecoderConfig {
  requireH265(
    sps.color.fullRange === false &&
      sps.color.colourPrimaries === 1 &&
      sps.color.transferCharacteristics === 1 &&
      sps.color.matrixCoefficients === 1,
    "sps.vui",
    "HEVC decoder configuration requires BT.709 limited-range signalling"
  );
  return Object.freeze({
    codec: h265CodecString(sps.profileTierLevel),
    codedWidth: sps.codedWidth,
    codedHeight: sps.codedHeight,
    displayAspectWidth: sps.crop.visibleWidth,
    displayAspectHeight: sps.crop.visibleHeight,
    colorSpace: Object.freeze({
      primaries: "bt709" as const,
      transfer: "bt709" as const,
      matrix: "bt709" as const,
      fullRange: false as const
    })
  });
}
