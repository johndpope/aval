import {
  canonicalizeH265EncoderUnitStream,
  deriveVideoRenditionGeometry,
  FormatError,
  h264CodecForLevel,
  inspectH265AnnexBRendition,
  prepareH264EncoderRendition,
  type H264RenditionInspection,
  type H265RenditionInspection,
  type VideoLayout
} from "@pixel-point/aval-format";

import { CompilerError } from "../diagnostics.js";
import {
  createEncodeVideoUnitInvocation,
  encodeElementaryVideoUnit,
  encodeIvfVideoUnit
} from "../ffmpeg/video-encode-unit.js";
import type {
  CompileInvocationDetails,
  NormalizedSourceProject,
  NormalizedVideoEncoding
} from "../model.js";
import {
  createExtractRgba16RangeInvocation,
  extractRgba16Range
} from "../ffmpeg/encode-unit.js";
import {
  prepareAv1Rendition,
  prepareVp9Rendition,
  type IvfEncodedUnitInput
} from "./ivf-codec-adapters.js";
import type { PreparedEncodingRendition } from "./project-encoding-compiler.js";
import {
  resolvePreparedFrameRange,
  type PreparedProjectSource
} from "./project-source.js";
import { writeVideoYuvUnitSpool } from "./video-yuv-spool.js";

export interface CompileVideoEncodingRenditionsInput {
  readonly project: Readonly<NormalizedSourceProject>;
  readonly encoding: Readonly<NormalizedVideoEncoding>;
  readonly layout: VideoLayout;
  readonly sources: ReadonlyMap<string, Readonly<PreparedProjectSource>>;
  readonly executable: string;
  readonly timeoutMs?: number;
  readonly signal?: AbortSignal;
}

export interface CompiledVideoEncodingRenditions {
  readonly renditions: readonly Readonly<PreparedEncodingRendition>[];
  readonly invocations: readonly Readonly<CompileInvocationDetails>[];
}

interface EncodedElementaryUnit {
  readonly id: string;
  readonly expectedFrames: number;
  readonly rawBytes: Uint8Array;
}

/** Compile every rendition of one codec through the shared RGBA16/YUV path. */
export async function compileVideoEncodingRenditions(
  input: Readonly<CompileVideoEncodingRenditionsInput>
): Promise<Readonly<CompiledVideoEncodingRenditions>> {
  const renditions: PreparedEncodingRendition[] = [];
  const invocations: CompileInvocationDetails[] = [];
  for (const rendition of input.encoding.renditions) {
    const geometry = deriveVideoRenditionGeometry({
      canvasWidth: input.project.canvas.width,
      canvasHeight: input.project.canvas.height,
      layout: input.layout,
      visibleWidth: rendition.width,
      visibleHeight: rendition.height,
      // An H.264 SPS declares coded dimensions in whole 16x16 macroblocks.
      // Pad the canonical surface before x264 sees it so the compiler-owned
      // geometry, SPS crop, manifest, and decoded storage all agree.
      storage: input.encoding.codec === "h264"
        ? { widthAlignment: 16, heightAlignment: 16 }
        : { widthAlignment: 2, heightAlignment: 2 }
    });
    const encodedUnits: EncodedElementaryUnit[] | IvfEncodedUnitInput[] = [];
    for (const unit of input.project.units) {
      const source = input.sources.get(unit.source);
      if (source === undefined) {
        throw new CompilerError("IO_FAILED", `Prepared source ${unit.source} is missing`);
      }
      const [startFrame, endFrame] = resolvePreparedFrameRange(
        source,
        unit.range[0],
        unit.range[1]
      );
      const extraction = {
        source: source.input,
        startFrame,
        endFrame,
        width: rendition.width,
        height: rendition.height,
        executable: input.executable,
        ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs }),
        ...(input.signal === undefined ? {} : { signal: input.signal })
      };
      invocations.push(Object.freeze({
        operation: `${input.encoding.codec}:${rendition.id}:${unit.id}:scale-rgba`,
        tool: "ffmpeg",
        arguments: redactArguments(
          createExtractRgba16RangeInvocation(extraction).arguments,
          source.input.path,
          `$SPOOL/${unit.source}`
        )
      }));
      const rgba16 = await extractRgba16Range(extraction);
      const bitDepth = input.encoding.codec === "av1" ? input.encoding.bitDepth : 8;
      const spool = await writeVideoYuvUnitSpool({
        geometry,
        frameRate: input.project.frameRate,
        bitDepth,
        frames: rgba16,
        ...(input.signal === undefined ? {} : { signal: input.signal })
      });
      try {
        if (input.encoding.codec === "h264" || input.encoding.codec === "h265") {
          const encodeInput = {
            source: spool.source,
            startFrame: 0,
            endFrame: spool.frameCount,
            encoding: input.encoding,
            rendition,
            geometry,
            executable: input.executable,
            ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs }),
            ...(input.signal === undefined ? {} : { signal: input.signal })
          };
          invocations.push(Object.freeze({
            operation: `${input.encoding.codec}:${rendition.id}:${unit.id}:encode`,
            tool: "ffmpeg",
            arguments: createEncodeVideoUnitInvocation(encodeInput).arguments
          }));
          (encodedUnits as EncodedElementaryUnit[]).push(Object.freeze({
            id: unit.id,
            expectedFrames: spool.frameCount,
            rawBytes: await encodeElementaryVideoUnit(encodeInput)
          }));
        } else {
          const encodeInput = {
            source: spool.source,
            startFrame: 0,
            endFrame: spool.frameCount,
            encoding: input.encoding,
            rendition,
            geometry,
            executable: input.executable,
            ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs }),
            ...(input.signal === undefined ? {} : { signal: input.signal })
          };
          invocations.push(Object.freeze({
            operation: `${input.encoding.codec}:${rendition.id}:${unit.id}:encode`,
            tool: "ffmpeg",
            arguments: createEncodeVideoUnitInvocation(encodeInput).arguments
          }));
          const encoded = await encodeIvfVideoUnit(encodeInput);
          (encodedUnits as IvfEncodedUnitInput[]).push(Object.freeze({
            id: unit.id,
            expectedDisplayedFrames: spool.frameCount,
            packets: encoded.packets
          }));
        }
      } finally {
        await spool.cleanup();
      }
    }
    renditions.push(input.encoding.codec === "h264"
      ? prepareH264Rendition({
          renditionId: rendition.id,
          geometry,
          frameRate: input.project.frameRate,
          units: encodedUnits as readonly EncodedElementaryUnit[]
        })
      : input.encoding.codec === "h265"
      ? prepareH265Rendition({
          renditionId: rendition.id,
          geometry,
          frameRate: input.project.frameRate,
          units: encodedUnits as readonly EncodedElementaryUnit[]
        })
      : prepareIvfRendition({
          encoding: input.encoding,
          renditionId: rendition.id,
          geometry,
          frameRate: input.project.frameRate,
          units: encodedUnits as readonly IvfEncodedUnitInput[]
        }));
  }
  return Object.freeze({
    renditions: Object.freeze(renditions),
    invocations: Object.freeze(invocations)
  });
}

function prepareH264Rendition(input: Readonly<{
  readonly renditionId: string;
  readonly geometry: ReturnType<typeof deriveVideoRenditionGeometry>;
  readonly frameRate: NormalizedSourceProject["frameRate"];
  readonly units: readonly EncodedElementaryUnit[];
}>): Readonly<PreparedEncodingRendition> {
  let prepared: ReturnType<typeof prepareH264EncoderRendition>;
  try {
    prepared = prepareH264EncoderRendition({
      profile: {
        codedWidth: input.geometry.codedWidth,
        codedHeight: input.geometry.codedHeight,
        expectedVisibleRect: Object.freeze([
          0,
          0,
          input.geometry.decodedStorageRect[2],
          input.geometry.decodedStorageRect[3]
        ] as const),
        frameRate: input.frameRate,
        requireBt709LimitedRange: true
      },
      units: input.units.map((unit) => Object.freeze({
        id: unit.id,
        bytes: unit.rawBytes,
        expectedAccessUnitCount: unit.expectedFrames
      }))
    });
  } catch (cause) {
    if (cause instanceof FormatError) {
      throw new CompilerError("H264_BITSTREAM_INVALID", cause.message, {
        cause,
        rendition: input.renditionId
      });
    }
    throw cause;
  }
  const bitrate = measuredBitrate(
    prepared.units.flatMap(({ accessUnits }) => accessUnits.map(({ bytes }) => bytes)),
    input.units.reduce((total, { expectedFrames }) => total + expectedFrames, 0),
    input.frameRate,
    "H.264"
  );
  return Object.freeze({
    id: input.renditionId,
    codec: h264CodecForLevel(prepared.inspection.parameterSet.levelIdc),
    bitDepth: 8,
    geometry: input.geometry,
    bitrate: Object.freeze({ average: bitrate, peak: bitrate }),
    units: Object.freeze(prepared.units.map((unit, unitIndex) => {
      const inspected = requiredH264Unit(prepared.inspection, unitIndex, unit.id);
      return Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.accessUnits.map((accessUnit, decodeIndex) => {
          const summary = inspected.accessUnits[decodeIndex];
          if (summary === undefined || summary.decodeIndex !== decodeIndex) {
            throw new CompilerError(
              "ASSET_INVALID",
              "H.264 inspection omitted or reordered a decode access unit",
              { unit: unit.id }
            );
          }
          return Object.freeze({
            bytes: accessUnit.bytes,
            presentationTimestamp: summary.presentationIndex,
            duration: 1,
            randomAccess: summary.key,
            displayedFrameCount: 1
          });
        }))
      });
    }))
  });
}

function requiredH264Unit(
  inspection: Readonly<H264RenditionInspection>,
  index: number,
  id: string
): H264RenditionInspection["units"][number] {
  const unit = inspection.units[index];
  if (unit === undefined || unit.id !== id) {
    throw new CompilerError(
      "ASSET_INVALID",
      "H.264 inspection unit order changed",
      { unit: id }
    );
  }
  return unit;
}

function prepareH265Rendition(input: Readonly<{
  readonly renditionId: string;
  readonly geometry: ReturnType<typeof deriveVideoRenditionGeometry>;
  readonly frameRate: NormalizedSourceProject["frameRate"];
  readonly units: readonly EncodedElementaryUnit[];
}>): Readonly<PreparedEncodingRendition> {
  const canonicalUnits = input.units.map((unit) => Object.freeze({
    id: unit.id,
    accessUnits: canonicalizeH265EncoderUnitStream(
      unit.rawBytes,
      unit.expectedFrames,
      `units.${unit.id}`
    )
  }));
  const inspection = inspectH265AnnexBRendition({
    profile: {
      codedWidth: input.geometry.codedWidth,
      codedHeight: input.geometry.codedHeight,
      expectedVisibleRect: Object.freeze([
        0,
        0,
        input.geometry.decodedStorageRect[2],
        input.geometry.decodedStorageRect[3]
      ] as const),
      frameRate: input.frameRate,
      requireBt709LimitedRange: true
    },
    units: canonicalUnits
  });
  const bitrate = measuredBitrate(
    canonicalUnits.flatMap(({ accessUnits }) => accessUnits.map(({ bytes }) => bytes)),
    input.units.reduce((total, { expectedFrames }) => total + expectedFrames, 0),
    input.frameRate,
    "H.265"
  );
  return Object.freeze({
    id: input.renditionId,
    codec: inspection.decoderConfig.codec,
    bitDepth: 8,
    geometry: input.geometry,
    bitrate: Object.freeze({ average: bitrate, peak: bitrate }),
    units: Object.freeze(canonicalUnits.map((unit, unitIndex) => {
      const inspected = requiredH265Unit(inspection, unitIndex, unit.id);
      return Object.freeze({
        id: unit.id,
        chunks: Object.freeze(unit.accessUnits.map((accessUnit, decodeIndex) => {
          const summary = inspected.accessUnits[decodeIndex];
          if (summary === undefined) {
            throw new CompilerError("ASSET_INVALID", "HEVC inspection omitted an access unit", {
              unit: unit.id
            });
          }
          return Object.freeze({
            bytes: accessUnit.bytes,
            presentationTimestamp: summary.presentationIndex,
            duration: 1,
            randomAccess: summary.key,
            displayedFrameCount: 1
          });
        }))
      });
    }))
  });
}

function requiredH265Unit(
  inspection: Readonly<H265RenditionInspection>,
  index: number,
  id: string
): H265RenditionInspection["units"][number] {
  const unit = inspection.units[index];
  if (unit === undefined || unit.id !== id) {
    throw new CompilerError("ASSET_INVALID", "HEVC inspection unit order changed", { unit: id });
  }
  return unit;
}

function prepareIvfRendition(input: Readonly<{
  readonly encoding: Extract<
    NormalizedVideoEncoding,
    { readonly codec: "vp9" | "av1" }
  >;
  readonly renditionId: string;
  readonly geometry: ReturnType<typeof deriveVideoRenditionGeometry>;
  readonly frameRate: NormalizedSourceProject["frameRate"];
  readonly units: readonly IvfEncodedUnitInput[];
}>): Readonly<PreparedEncodingRendition> {
  const prepared = input.encoding.codec === "vp9"
    ? prepareVp9Rendition({
        width: input.geometry.codedWidth,
        height: input.geometry.codedHeight,
        frameRate: input.frameRate,
        units: input.units
      })
    : prepareAv1Rendition({
        width: input.geometry.codedWidth,
        height: input.geometry.codedHeight,
        bitDepth: input.encoding.bitDepth,
        frameRate: input.frameRate,
        units: input.units
      });
  return Object.freeze({
    id: input.renditionId,
    codec: prepared.codec,
    bitDepth: prepared.bitDepth,
    geometry: input.geometry,
    bitrate: prepared.bitrate,
    units: prepared.units.map(({ id, chunks }) => Object.freeze({ id, chunks }))
  });
}

function measuredBitrate(
  chunks: readonly Uint8Array[],
  frames: number,
  frameRate: NormalizedSourceProject["frameRate"],
  codec: string
): number {
  let bytes = 0;
  for (const chunk of chunks) {
    bytes = checkedAdd(bytes, chunk.byteLength, `${codec} encoded bytes`);
  }
  const numerator = bytes * 8 * frameRate.numerator;
  const denominator = frames * frameRate.denominator;
  if (!Number.isSafeInteger(numerator) || !Number.isSafeInteger(denominator) || denominator < 1) {
    throw new CompilerError("OUTPUT_LIMIT", `${codec} bitrate exceeds safe arithmetic`);
  }
  return Math.max(1, Math.ceil(numerator / denominator));
}

function checkedAdd(left: number, right: number, label: string): number {
  const result = left + right;
  if (!Number.isSafeInteger(result) || result < 0) {
    throw new CompilerError("OUTPUT_LIMIT", `${label} exceeds safe arithmetic`);
  }
  return result;
}

function redactArguments(
  arguments_: readonly string[],
  path: string,
  token: string
): readonly string[] {
  return Object.freeze(arguments_.map((argument) =>
    argument.split(path).join(token)
  ));
}
