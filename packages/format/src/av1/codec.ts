import { FormatError } from "../errors.js";
import type { Av1SequenceHeader } from "./sequence-header.js";

export type Av1Codec = `av01.0.${string}.${"08" | "10"}.0.11${0 | 1 | 2 | 3}.01.01.01.0`;

export function av1CodecFromSequence(
  sequence: Readonly<Av1SequenceHeader>
): Av1Codec {
  if (!Number.isInteger(sequence.level) || sequence.level < 0 || sequence.level > 31) {
    throw new FormatError("PROFILE_INVALID", "AV1 level is invalid");
  }
  const level = String(sequence.level).padStart(2, "0");
  const bitDepth = String(sequence.bitDepth).padStart(2, "0") as "08" | "10";
  return `av01.0.${level}${sequence.tier}.${bitDepth}.0.11${sequence.chromaSamplePosition}.01.01.01.0`;
}

export function isAv1Codec(value: unknown): value is Av1Codec {
  return typeof value === "string" &&
    /^av01\.0\.(?:0[0-9]|[12][0-9]|3[01])[MH]\.(?:08|10)\.0\.11[0-3]\.01\.01\.01\.0$/u.test(value);
}
