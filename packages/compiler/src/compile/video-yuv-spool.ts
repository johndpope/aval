import { mkdtemp, open, rm, statfs } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { VideoRenditionGeometry } from "@pixel-point/aval-format";

import { throwIfAborted } from "../cancellation.js";
import { CompilerError } from "../diagnostics.js";
import type { RawYuv420FrameSource } from "../ffmpeg/video-encode-unit.js";
import type { Rational } from "../model.js";
import { convertRgba16ToYuv420 } from "./rgba16-to-yuv420.js";
import { composeVideoSurfaceRgba16 } from "./video-surface-rgba16.js";

const DISK_HEADROOM_BYTES = 64 * 1024 * 1024;

export interface VideoYuvUnitSpool {
  readonly source: Readonly<RawYuv420FrameSource>;
  readonly frameCount: number;
  readonly cleanup: () => Promise<void>;
}

export interface WriteVideoYuvUnitSpoolInput {
  readonly geometry: Readonly<VideoRenditionGeometry>;
  readonly frameRate: Readonly<Rational>;
  readonly bitDepth: 8 | 10;
  readonly frames: readonly Uint16Array[];
  readonly temporaryRoot?: string;
  readonly signal?: AbortSignal;
}

/** Write complete visible RGBA16 frames into a private codec-neutral YUV spool. */
export async function writeVideoYuvUnitSpool(
  input: Readonly<WriteVideoYuvUnitSpoolInput>
): Promise<Readonly<VideoYuvUnitSpool>> {
  throwIfAborted(input.signal);
  validate(input);
  const bytesPerSample = input.bitDepth === 10 ? 2 : 1;
  const frameBytes = checkedProduct(
    input.geometry.codedWidth,
    input.geometry.codedHeight,
    3
  ) / 2 * bytesPerSample;
  if (!Number.isSafeInteger(frameBytes)) {
    throw invalid("YUV spool geometry is not 4:2:0 aligned");
  }
  const totalBytes = checkedProduct(frameBytes, input.frames.length);
  const root = input.temporaryRoot ?? tmpdir();
  await requireDisk(root, totalBytes);
  const directory = await createDirectory(root);
  const path = join(directory, input.bitDepth === 10 ? "unit-10.yuv" : "unit-8.yuv");
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  let complete = false;
  try {
    handle = await open(path, "wx", 0o600);
    for (const frame of input.frames) {
      throwIfAborted(input.signal);
      const surface = composeVideoSurfaceRgba16(frame, input.geometry);
      const yuv = convertRgba16ToYuv420(surface, {
        width: input.geometry.codedWidth,
        height: input.geometry.codedHeight,
        bitDepth: input.bitDepth
      });
      if (yuv.byteLength !== frameBytes) {
        throw new CompilerError("IO_FAILED", "YUV spool frame byte count changed");
      }
      await writeAll(handle, yuv, input.signal);
    }
    await handle.sync();
    await handle.close();
    handle = undefined;
    complete = true;
  } catch (error) {
    await handle?.close().catch(() => undefined);
    await rm(directory, { recursive: true, force: true }).catch(() => undefined);
    throw error;
  }
  if (!complete) {
    await rm(directory, { recursive: true, force: true }).catch(() => undefined);
    throw new CompilerError("IO_FAILED", "YUV spool did not complete");
  }
  return Object.freeze({
    source: Object.freeze({
      path,
      width: input.geometry.codedWidth,
      height: input.geometry.codedHeight,
      bitDepth: input.bitDepth,
      frameRate: Object.freeze({ ...input.frameRate }),
      frameBytes
    }),
    frameCount: input.frames.length,
    cleanup: () => cleanup(directory)
  });
}

function validate(input: Readonly<WriteVideoYuvUnitSpoolInput>): void {
  if (typeof input !== "object" || input === null) {
    throw invalid("YUV spool input must be an object");
  }
  if (input.bitDepth !== 8 && input.bitDepth !== 10) {
    throw invalid("YUV spool bit depth must be 8 or 10");
  }
  if (!Array.isArray(input.frames) || input.frames.length < 1) {
    throw invalid("YUV spool requires at least one frame");
  }
  if (
    !Number.isSafeInteger(input.frameRate?.numerator) ||
    !Number.isSafeInteger(input.frameRate?.denominator) ||
    input.frameRate.numerator < 1 ||
    input.frameRate.denominator < 1
  ) {
    throw invalid("YUV spool frame rate must be a positive rational");
  }
  const visible = input.geometry?.visibleColorRect;
  const expectedLength = visible === undefined
    ? -1
    : checkedProduct(visible[2], visible[3], 4);
  for (const frame of input.frames) {
    if (!(frame instanceof Uint16Array) || frame.length !== expectedLength) {
      throw invalid("RGBA16 frame length does not match the visible geometry");
    }
  }
}

async function createDirectory(root: string): Promise<string> {
  try {
    return await mkdtemp(join(root, "aval-video-yuv-"));
  } catch (cause) {
    throw new CompilerError("IO_FAILED", "Could not create private YUV spool", {
      cause
    });
  }
}

async function requireDisk(root: string, bytes: number): Promise<void> {
  try {
    const filesystem = await statfs(root);
    const available = BigInt(filesystem.bavail) * BigInt(filesystem.bsize);
    if (available < BigInt(bytes) + BigInt(DISK_HEADROOM_BYTES)) {
      throw new CompilerError(
        "SOURCE_LIMIT",
        "Insufficient temporary disk space for the YUV spool"
      );
    }
  } catch (error) {
    if (error instanceof CompilerError) throw error;
    throw new CompilerError("IO_FAILED", "Could not inspect YUV spool storage", {
      cause: error
    });
  }
}

async function writeAll(
  handle: Awaited<ReturnType<typeof open>>,
  bytes: Uint8Array,
  signal?: AbortSignal
): Promise<void> {
  let offset = 0;
  while (offset < bytes.byteLength) {
    throwIfAborted(signal);
    const result = await handle.write(bytes, offset, bytes.byteLength - offset);
    if (result.bytesWritten < 1) {
      throw new CompilerError("IO_FAILED", "YUV spool write made no progress");
    }
    offset += result.bytesWritten;
  }
}

async function cleanup(directory: string): Promise<void> {
  try {
    await rm(directory, { recursive: true, force: true });
  } catch (cause) {
    throw new CompilerError("IO_FAILED", "Could not remove private YUV spool", {
      cause
    });
  }
}

function checkedProduct(...values: number[]): number {
  let result = 1;
  for (const value of values) {
    result *= value;
    if (!Number.isSafeInteger(result) || result < 0) {
      throw invalid("YUV spool size exceeds the safe integer range");
    }
  }
  return result;
}

function invalid(message: string): CompilerError {
  return new CompilerError("INPUT_INVALID", message, { phase: "pixel-pipeline" });
}
