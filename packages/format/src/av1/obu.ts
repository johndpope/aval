import { FormatError } from "../errors.js";
import { readAv1Leb128 } from "./leb128.js";

export const AV1_OBU_SEQUENCE_HEADER = 1;
export const AV1_OBU_TEMPORAL_DELIMITER = 2;
export const AV1_OBU_FRAME_HEADER = 3;
export const AV1_OBU_TILE_GROUP = 4;
export const AV1_OBU_METADATA = 5;
export const AV1_OBU_FRAME = 6;
export const AV1_OBU_REDUNDANT_FRAME_HEADER = 7;
export const AV1_OBU_TILE_LIST = 8;
export const AV1_OBU_PADDING = 15;

const ALLOWED_OBU_TYPES = new Set([
  AV1_OBU_SEQUENCE_HEADER,
  AV1_OBU_TEMPORAL_DELIMITER,
  AV1_OBU_FRAME_HEADER,
  AV1_OBU_TILE_GROUP,
  AV1_OBU_METADATA,
  AV1_OBU_FRAME,
  AV1_OBU_REDUNDANT_FRAME_HEADER,
  AV1_OBU_PADDING
]);

export interface Av1Obu {
  readonly type: number;
  readonly temporalId: number;
  readonly spatialId: number;
  readonly payload: Uint8Array;
}

/** Parse one low-overhead temporal unit into owned OBU payloads. */
export function parseAv1LowOverheadObus(
  bytes: Uint8Array,
  path = "av1.temporalUnit"
): readonly Av1Obu[] {
  requireAv1(bytes instanceof Uint8Array, path, "temporal unit must be bytes");
  requireAv1(bytes.byteLength > 0, path, "temporal unit is empty");
  const output: Av1Obu[] = [];
  let cursor = 0;
  while (cursor < bytes.byteLength) {
    const headerOffset = cursor;
    const header = bytes[cursor];
    requireAv1(header !== undefined, path, "OBU header is truncated", cursor);
    cursor += 1;
    requireAv1((header & 0x80) === 0, path, "obu_forbidden_bit must be zero", headerOffset);
    const type = (header >> 3) & 0x0f;
    const extension = (header & 0x04) !== 0;
    const hasSize = (header & 0x02) !== 0;
    requireAv1((header & 0x01) === 0, path, "OBU reserved bit must be zero", headerOffset);
    requireAv1(hasSize, path, "low-overhead OBU requires a size field", headerOffset);
    requireAv1(ALLOWED_OBU_TYPES.has(type), path, `OBU type ${String(type)} is unsupported`, headerOffset);
    requireAv1(type !== AV1_OBU_TILE_LIST, path, "tile-list OBU is unsupported", headerOffset);

    let temporalId = 0;
    let spatialId = 0;
    if (extension) {
      const extensionByte = bytes[cursor];
      requireAv1(extensionByte !== undefined, path, "OBU extension is truncated", cursor);
      cursor += 1;
      temporalId = extensionByte >> 5;
      spatialId = (extensionByte >> 3) & 0x03;
      requireAv1((extensionByte & 0x07) === 0, path, "OBU extension reserved bits must be zero", cursor - 1);
      requireAv1(temporalId === 0 && spatialId === 0, path, "scalable AV1 layers are unsupported", cursor - 1);
    }

    const size = readAv1Leb128(bytes, cursor, `${path}.obuSize`);
    cursor += size.length;
    requireAv1(size.value <= bytes.byteLength - cursor, path, "OBU payload is truncated", cursor);
    const payload = bytes.slice(cursor, cursor + size.value);
    cursor += size.value;
    if (type === AV1_OBU_TEMPORAL_DELIMITER) {
      requireAv1(payload.byteLength === 0, path, "temporal delimiter payload must be empty", headerOffset);
    }
    output.push(Object.freeze({ type, temporalId, spatialId, payload }));
  }
  return Object.freeze(output);
}

function requireAv1(
  condition: boolean,
  path: string,
  message: string,
  offset?: number
): asserts condition {
  if (!condition) {
    throw new FormatError("PROFILE_INVALID", `AV1 ${message}`, {
      path,
      ...(offset === undefined ? {} : { offset })
    });
  }
}
