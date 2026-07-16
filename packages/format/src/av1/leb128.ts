import { FormatError } from "../errors.js";

export interface Av1Leb128 {
  readonly value: number;
  readonly length: number;
}

/** Read a canonical unsigned LEB128 value bounded to safe integers. */
export function readAv1Leb128(
  bytes: Uint8Array,
  offset: number,
  path = "av1.leb128"
): Readonly<Av1Leb128> {
  if (!(bytes instanceof Uint8Array) || !Number.isSafeInteger(offset) || offset < 0) {
    throw new FormatError("PROFILE_INVALID", "AV1 LEB128 input is invalid", { path });
  }
  let value = 0n;
  let length = 0;
  for (; length < 8; length += 1) {
    const byte = bytes[offset + length];
    if (byte === undefined) {
      throw new FormatError("PROFILE_INVALID", "AV1 LEB128 is truncated", {
        path,
        offset: offset + length
      });
    }
    value |= BigInt(byte & 0x7f) << BigInt(length * 7);
    if ((byte & 0x80) === 0) {
      const byteLength = length + 1;
      if (byteLength > 1 && value < (1n << BigInt((byteLength - 1) * 7))) {
        throw new FormatError("PROFILE_INVALID", "AV1 LEB128 is non-canonical", {
          path,
          offset
        });
      }
      if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw new FormatError("PROFILE_INVALID", "AV1 LEB128 is unsafe", {
          path,
          offset
        });
      }
      return Object.freeze({ value: Number(value), length: byteLength });
    }
  }
  throw new FormatError("PROFILE_INVALID", "AV1 LEB128 exceeds eight bytes", {
    path,
    offset
  });
}

export function encodeAv1Leb128(value: number): Uint8Array {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new FormatError("PROFILE_INVALID", "AV1 LEB128 value is invalid");
  }
  const bytes: number[] = [];
  let remaining = BigInt(value);
  do {
    let byte = Number(remaining & 0x7fn);
    remaining >>= 7n;
    if (remaining !== 0n) byte |= 0x80;
    bytes.push(byte);
  } while (remaining !== 0n);
  return Uint8Array.from(bytes);
}
