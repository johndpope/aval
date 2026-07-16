import type {
  H265AccessUnitInput,
  H265RenditionInspectionInput,
  H265UnitInput
} from "../src/h265/index.js";

export class H265BitWriter {
  readonly #bits: number[] = [];

  public bit(value: boolean | number): this {
    this.#bits.push(value ? 1 : 0);
    return this;
  }

  public bits(value: number, width: number): this {
    for (let shift = width - 1; shift >= 0; shift -= 1) {
      this.bit(Math.floor(value / 2 ** shift) % 2);
    }
    return this;
  }

  public ue(value: number): this {
    const code = value + 1;
    const width = Math.floor(Math.log2(code)) + 1;
    for (let index = 1; index < width; index += 1) this.bit(0);
    return this.bits(code, width);
  }

  public se(value: number): this {
    return this.ue(value <= 0 ? -2 * value : value * 2 - 1);
  }

  public trailing(): this {
    this.bit(true);
    while (this.#bits.length % 8 !== 0) this.bit(false);
    return this;
  }

  public opaqueByte(value = 0x55): this {
    return this.bits(value, 8);
  }

  public toBytes(): Uint8Array {
    if (this.#bits.length % 8 !== 0) {
      throw new Error("fixture bitstream must be byte aligned");
    }
    const bytes = new Uint8Array(this.#bits.length / 8);
    for (let index = 0; index < this.#bits.length; index += 1) {
      if (this.#bits[index] === 1) {
        const byteIndex = Math.floor(index / 8);
        bytes[byteIndex] = (bytes[byteIndex] ?? 0) | (1 << (7 - (index % 8)));
      }
    }
    return bytes;
  }
}

export interface H265PtlFixtureOptions {
  readonly profileSpace?: number;
  readonly tier?: boolean;
  readonly profileIdc?: number;
  readonly compatibilityProfileIndexes?: readonly number[];
  readonly constraintBytes?: readonly number[];
  readonly levelIdc?: number;
}

function writePtl(writer: H265BitWriter, options: H265PtlFixtureOptions = {}): void {
  writer
    .bits(options.profileSpace ?? 0, 2)
    .bit(options.tier === true)
    .bits(options.profileIdc ?? 1, 5);
  const compatible = new Set(options.compatibilityProfileIndexes ?? [1, 2]);
  for (let index = 0; index < 32; index += 1) writer.bit(compatible.has(index));
  const constraints = options.constraintBytes ?? [0x90, 0, 0, 0, 0, 0];
  for (let index = 0; index < 6; index += 1) writer.bits(constraints[index] ?? 0, 8);
  writer.bits(options.levelIdc ?? 30, 8);
}

export function makeH265Vps(
  ptl: H265PtlFixtureOptions = {},
  id = 0
): Uint8Array {
  const writer = new H265BitWriter()
    .bits(id, 4)
    .bit(true)
    .bit(true)
    .bits(0, 6)
    .bits(0, 3)
    .bit(true)
    .bits(0xffff, 16);
  writePtl(writer, ptl);
  writer
    .bit(true)
    .ue(4)
    .ue(2)
    .ue(0)
    .bits(0, 6)
    .ue(0)
    .bit(false)
    .bit(false)
    .trailing();
  return h265Nal(32, writer.toBytes());
}

export interface H265SpsFixtureOptions {
  readonly ptl?: H265PtlFixtureOptions;
  readonly vpsId?: number;
  readonly spsId?: number;
  readonly width?: number;
  readonly height?: number;
  readonly crop?: readonly [left: number, right: number, top: number, bottom: number];
  readonly bitDepthMinus8?: number;
  readonly maxReorder?: number;
  readonly maxBufferMinus1?: number;
  readonly numUnitsInTick?: number;
  readonly timeScale?: number;
  readonly color?: readonly [primaries: number, transfer: number, matrix: number];
  readonly fullRange?: boolean;
  readonly includeVui?: boolean;
  readonly longTermReferences?: boolean;
}

export function makeH265Sps(options: H265SpsFixtureOptions = {}): Uint8Array {
  const writer = new H265BitWriter()
    .bits(options.vpsId ?? 0, 4)
    .bits(0, 3)
    .bit(true);
  writePtl(writer, options.ptl);
  writer
    .ue(options.spsId ?? 0)
    .ue(1)
    .ue(options.width ?? 64)
    .ue(options.height ?? 64);
  const crop = options.crop;
  writer.bit(crop !== undefined);
  if (crop !== undefined) {
    writer.ue(crop[0]).ue(crop[1]).ue(crop[2]).ue(crop[3]);
  }
  writer
    .ue(options.bitDepthMinus8 ?? 0)
    .ue(options.bitDepthMinus8 ?? 0)
    .ue(4)
    .bit(true)
    .ue(options.maxBufferMinus1 ?? 4)
    .ue(options.maxReorder ?? 2)
    .ue(0)
    .ue(0)
    .ue(3)
    .ue(0)
    .ue(3)
    .ue(0)
    .ue(0)
    .bit(false)
    .bit(false)
    .bit(true)
    .bit(false)
    .ue(0)
    .bit(options.longTermReferences === true);
  if (options.longTermReferences === true) writer.ue(0);
  writer
    .bit(true)
    .bit(true)
    .bit(options.includeVui !== false);
  if (options.includeVui !== false) {
    const color = options.color ?? [1, 1, 1];
    writer
      .bit(true)
      .bits(1, 8)
      .bit(false)
      .bit(true)
      .bits(5, 3)
      .bit(options.fullRange === true)
      .bit(true)
      .bits(color[0], 8)
      .bits(color[1], 8)
      .bits(color[2], 8)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(false)
      .bit(true)
      .bits(options.numUnitsInTick ?? 1, 32)
      .bits(options.timeScale ?? 5, 32)
      .bit(false)
      .bit(false)
      .bit(false);
  }
  writer.bit(false).trailing();
  return h265Nal(33, writer.toBytes());
}

export function makeH265Pps(spsId = 0, ppsId = 0): Uint8Array {
  const writer = new H265BitWriter()
    .ue(ppsId)
    .ue(spsId)
    .bit(false)
    .bit(false)
    .bits(0, 3)
    .bit(true)
    .bit(false)
    .ue(0)
    .ue(0)
    .se(0)
    .bit(false)
    .bit(false)
    .bit(false)
    .se(0)
    .se(0)
    .bit(false)
    .bit(false)
    .bit(false)
    .bit(false)
    .bit(false)
    .bit(true)
    .bit(true)
    .bit(true)
    .bit(false)
    .bit(false)
    .se(0)
    .se(0)
    .bit(false)
    .bit(false)
    .ue(0)
    .bit(false)
    .bit(false)
    .trailing();
  return h265Nal(34, writer.toBytes());
}

export function makeH265Aud(pictureType: 0 | 1 | 2): Uint8Array {
  return h265Nal(35, new H265BitWriter().bits(pictureType, 3).trailing().toBytes());
}

export interface H265SliceFixtureOptions {
  readonly nalType: number;
  readonly sliceType: "I" | "P" | "B";
  readonly poc?: number;
  readonly negativeReferences?: readonly number[];
  readonly positiveReferences?: readonly number[];
  readonly noOutputOfPriorPictures?: boolean;
  readonly ppsId?: number;
  readonly opaqueBytes?: number;
}

export function makeH265Slice(options: H265SliceFixtureOptions): Uint8Array {
  const writer = new H265BitWriter().bit(true);
  if (options.nalType >= 16 && options.nalType <= 21) {
    writer.bit(options.noOutputOfPriorPictures === true);
  }
  writer
    .ue(options.ppsId ?? 0)
    .ue(options.sliceType === "I" ? 2 : options.sliceType === "P" ? 1 : 0);
  if (options.nalType !== 19 && options.nalType !== 20) {
    writer.bits(options.poc ?? 0, 8).bit(false);
    const negative = options.negativeReferences ?? [];
    const positive = options.positiveReferences ?? [];
    writer.ue(negative.length).ue(positive.length);
    let previous = 0;
    for (const delta of negative) {
      if (delta >= previous || delta >= 0) throw new Error("negative RPS must decrease");
      writer.ue(previous - delta - 1).bit(true);
      previous = delta;
    }
    previous = 0;
    for (const delta of positive) {
      if (delta <= previous) throw new Error("positive RPS must increase");
      writer.ue(delta - previous - 1).bit(true);
      previous = delta;
    }
    writer.bit(false);
  }
  writer.trailing();
  for (let index = 0; index < (options.opaqueBytes ?? 4); index += 1) {
    writer.opaqueByte(0x55 + (index % 2));
  }
  return h265Nal(options.nalType, writer.toBytes());
}

export function makeH265AccessUnit(options: {
  readonly slice: H265SliceFixtureOptions;
  readonly vps?: Uint8Array;
  readonly sps?: Uint8Array;
  readonly pps?: Uint8Array;
  readonly metadata?: readonly Uint8Array[];
  readonly prefixLength?: 3 | 4;
}): H265AccessUnitInput {
  const isKey = options.slice.nalType >= 16 && options.slice.nalType <= 21;
  const pictureType = options.slice.sliceType === "I" ? 0 : options.slice.sliceType === "P" ? 1 : 2;
  const nals = [
    makeH265Aud(pictureType),
    ...(options.vps === undefined ? [] : [options.vps]),
    ...(options.sps === undefined ? [] : [options.sps]),
    ...(options.pps === undefined ? [] : [options.pps]),
    ...(options.metadata ?? []),
    makeH265Slice(options.slice)
  ];
  const bytes = concat(nals);
  if (options.prefixLength === 3) {
    return { key: isKey, bytes: replaceStartCodes(bytes, 3) };
  }
  return { key: isKey, bytes };
}

export function makeH265Unit(id = "idle"): H265UnitInput {
  const vps = makeH265Vps();
  const sps = makeH265Sps();
  const pps = makeH265Pps();
  return {
    id,
    accessUnits: [
      makeH265AccessUnit({
        vps,
        sps,
        pps,
        slice: { nalType: 20, sliceType: "I" }
      }),
      makeH265AccessUnit({
        slice: { nalType: 1, sliceType: "P", poc: 4, negativeReferences: [-4] }
      }),
      makeH265AccessUnit({
        slice: {
          nalType: 1,
          sliceType: "B",
          poc: 2,
          negativeReferences: [-2],
          positiveReferences: [2]
        }
      }),
      makeH265AccessUnit({
        slice: {
          nalType: 0,
          sliceType: "B",
          poc: 1,
          negativeReferences: [-1],
          positiveReferences: [1]
        }
      }),
      makeH265AccessUnit({
        slice: {
          nalType: 0,
          sliceType: "B",
          poc: 3,
          negativeReferences: [-1],
          positiveReferences: [1]
        }
      }),
      makeH265AccessUnit({
        slice: { nalType: 1, sliceType: "P", poc: 5, negativeReferences: [-1] }
      })
    ]
  };
}

export function validH265InspectionInput(
  units: readonly H265UnitInput[] = [makeH265Unit()]
): H265RenditionInspectionInput {
  return {
    profile: {
      codedWidth: 64,
      codedHeight: 64,
      frameRate: { numerator: 5, denominator: 1 },
      requireBt709LimitedRange: true
    },
    units
  };
}

export function h265Nal(
  type: number,
  rbsp: Uint8Array,
  prefixLength: 3 | 4 = 4,
  temporalId = 0
): Uint8Array {
  const escaped = escapeRbsp(rbsp);
  const output = new Uint8Array(prefixLength + 2 + escaped.length);
  output.set(prefixLength === 4 ? [0, 0, 0, 1] : [0, 0, 1], 0);
  output[prefixLength] = type << 1;
  output[prefixLength + 1] = temporalId + 1;
  output.set(escaped, prefixLength + 2);
  return output;
}

export function concat(parts: readonly Uint8Array[]): Uint8Array {
  const length = parts.reduce((total, part) => total + part.length, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function escapeRbsp(rbsp: Uint8Array): Uint8Array {
  const output: number[] = [];
  let zeroCount = 0;
  for (const byte of rbsp) {
    if (zeroCount === 2 && byte <= 3) {
      output.push(3);
      zeroCount = 0;
    }
    output.push(byte);
    zeroCount = byte === 0 ? zeroCount + 1 : 0;
  }
  return Uint8Array.from(output);
}

function replaceStartCodes(bytes: Uint8Array, length: 3 | 4): Uint8Array {
  const parts: Uint8Array[] = [];
  let start = 0;
  for (let index = 0; index + 3 < bytes.length; index += 1) {
    if (bytes[index] === 0 && bytes[index + 1] === 0 && bytes[index + 2] === 0 && bytes[index + 3] === 1) {
      if (index > start) parts.push(bytes.subarray(start, index));
      parts.push(Uint8Array.from(length === 4 ? [0, 0, 0, 1] : [0, 0, 1]));
      start = index + 4;
      index += 3;
    }
  }
  parts.push(bytes.subarray(start));
  return concat(parts);
}
