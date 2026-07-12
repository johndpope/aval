import { constants as fsConstants, type BigIntStats } from "node:fs";
import { createHash } from "node:crypto";
import { lstat, open, realpath } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { DigestReference } from "./model.js";
import { CertificationValidationError } from "./status.js";

export interface ArtifactVerificationOptions {
  readonly maximumBytes: number;
  readonly allowedMediaTypes?: ReadonlySet<string>;
}

export interface ArtifactReadOptions extends ArtifactVerificationOptions {
  /** Retain complete bytes only for bounded attachments that will be parsed. */
  readonly retainBytes?: (reference: DigestReference) => boolean;
  /** Prefix and suffix retained for bounded container-structure inspection. */
  readonly inspectionBytes?: number;
  /** Deterministic race injection for verifier tests; production callers omit it. */
  readonly testHook?: (phase: "after-open" | "after-read", reference: DigestReference) => Promise<void>;
}

export interface VerifiedArtifact {
  readonly reference: DigestReference;
  readonly prefix: Uint8Array;
  readonly suffix: Uint8Array;
  readonly bytes: Uint8Array | null;
}

/** Stable nofollow read for bounded manifests that do not yet have an expected digest. */
export async function readStableBoundedFile(path: string, maximumBytes: number): Promise<Uint8Array> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1) throw new RangeError("maximumBytes is invalid");
  const beforePath = await lstat(path, { bigint: true });
  if (beforePath.isSymbolicLink() || !beforePath.isFile() || beforePath.size < 1n || beforePath.size > BigInt(maximumBytes)) throw new Error("file is not a bounded regular nofollow artifact");
  const canonicalBefore = await realpath(path);
  const noFollow = fsConstants.O_NOFOLLOW ?? 0;
  const handle = await open(path, fsConstants.O_RDONLY | noFollow);
  try {
    const before = await handle.stat({ bigint: true });
    if (!sameIdentity(beforePath, before)) throw new Error("file changed before secure open");
    const bytes = Buffer.alloc(Number(before.size));
    const hash = createHash("sha256");
    const total = await readHandle(handle, hash, bytes, createInspectionWindows(0));
    const after = await handle.stat({ bigint: true });
    const afterPath = await lstat(path, { bigint: true });
    const canonicalAfter = await realpath(path);
    if (!sameIdentity(before, after) || !sameIdentity(after, afterPath) || canonicalAfter !== canonicalBefore || total !== bytes.byteLength) throw new Error("file changed while being read");
    return bytes;
  } finally {
    await handle.close();
  }
}

export async function sha256File(path: string): Promise<{ readonly sha256: string; readonly byteLength: number }> {
  const noFollow = fsConstants.O_NOFOLLOW ?? 0;
  const handle = await open(path, fsConstants.O_RDONLY | noFollow);
  try {
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) throw new TypeError("artifact is not a regular file");
    const hash = createHash("sha256");
    const byteLength = await hashHandle(handle, hash);
    const after = await handle.stat({ bigint: true });
    if (!sameIdentity(before, after) || BigInt(byteLength) !== before.size) throw new Error("artifact changed while being hashed");
    return Object.freeze({ sha256: hash.digest("hex"), byteLength });
  } finally {
    await handle.close();
  }
}

export async function verifyArtifactReferences(
  root: string,
  references: readonly DigestReference[],
  options: ArtifactVerificationOptions
): Promise<void> {
  await readVerifiedArtifactReferences(root, references, options);
}

/** Verifies once from stable open handles and returns the exact verified bytes or inspection windows. */
export async function readVerifiedArtifactReferences(
  root: string,
  references: readonly DigestReference[],
  options: ArtifactReadOptions
): Promise<ReadonlyMap<string, VerifiedArtifact>> {
  validateOptions(options);
  const inspectionBytes = options.inspectionBytes ?? 64 * 1024;
  if (!Number.isSafeInteger(inspectionBytes) || inspectionBytes < 0 || inspectionBytes > 16 * 1024 * 1024) throw new RangeError("inspectionBytes is invalid");
  const canonicalRoot = await realpath(root);
  const ids = new Set<string>();
  const paths = new Set<string>();
  const verified = new Map<string, VerifiedArtifact>();
  for (const [index, reference] of references.entries()) {
    validateReference(reference, index, options, ids, paths);
    const candidate = resolve(canonicalRoot, reference.path);
    const beforePath = await lstat(candidate, { bigint: true });
    if (beforePath.isSymbolicLink()) fail(`artifacts[${index}].path`, "symbolic links are forbidden");
    if (!beforePath.isFile()) fail(`artifacts[${index}].path`, "artifact is not a regular file");
    if (beforePath.size > BigInt(options.maximumBytes)) fail(`artifacts[${index}].byteLength`, "physical artifact exceeds policy limit");
    const canonicalCandidate = await realpath(candidate);
    requireWithin(canonicalRoot, canonicalCandidate, index);
    const noFollow = fsConstants.O_NOFOLLOW ?? 0;
    const handle = await open(candidate, fsConstants.O_RDONLY | noFollow);
    try {
      const before = await handle.stat({ bigint: true });
      if (!before.isFile() || !sameIdentity(beforePath, before)) fail(`artifacts[${index}].path`, "artifact changed before secure open");
      if (before.size !== BigInt(reference.byteLength)) fail(`artifacts[${index}].byteLength`, `expected ${reference.byteLength}, got ${String(before.size)}`);
      await options.testHook?.("after-open", reference);
      const retained = options.retainBytes?.(reference) === true ? Buffer.alloc(reference.byteLength) : null;
      const windows = createInspectionWindows(Math.min(inspectionBytes, reference.byteLength));
      const hash = createHash("sha256");
      const byteLength = await readHandle(handle, hash, retained, windows);
      await options.testHook?.("after-read", reference);
      const after = await handle.stat({ bigint: true });
      const afterPath = await lstat(candidate, { bigint: true });
      const canonicalAfter = await realpath(candidate);
      requireWithin(canonicalRoot, canonicalAfter, index);
      if (
        !sameIdentity(before, after) || !sameIdentity(after, afterPath) ||
        canonicalAfter !== canonicalCandidate || byteLength !== reference.byteLength
      ) fail(`artifacts[${index}].path`, "artifact changed while being verified");
      const digest = hash.digest("hex");
      if (digest !== reference.sha256) fail(`artifacts[${index}].sha256`, "digest mismatch");
      verified.set(reference.id, Object.freeze({
        reference,
        prefix: windows.prefix.slice(0, Math.min(byteLength, windows.prefix.byteLength)),
        suffix: windows.suffixLength === 0
          ? new Uint8Array(0)
          : windows.suffix.slice(0, windows.suffixLength),
        bytes: retained
      }));
    } finally {
      await handle.close();
    }
  }
  return verified;
}

function validateOptions(options: ArtifactVerificationOptions): void {
  if (!Number.isSafeInteger(options.maximumBytes) || options.maximumBytes < 0) throw new RangeError("maximumBytes is invalid");
}

function validateReference(
  reference: DigestReference,
  index: number,
  options: ArtifactVerificationOptions,
  ids: Set<string>,
  paths: Set<string>
): void {
  if (ids.has(reference.id)) fail(`artifacts[${index}].id`, "duplicate artifact ID");
  if (paths.has(reference.path)) fail(`artifacts[${index}].path`, "duplicate artifact path");
  ids.add(reference.id);
  paths.add(reference.path);
  if (isAbsolute(reference.path) || reference.path.includes("\\") || reference.path.split("/").some((part) => part === ".." || part === "." || part === "")) fail(`artifacts[${index}].path`, "unsafe relative path");
  if (reference.byteLength > options.maximumBytes) fail(`artifacts[${index}].byteLength`, "artifact exceeds policy limit");
  if (options.allowedMediaTypes !== undefined && !options.allowedMediaTypes.has(reference.mediaType)) fail(`artifacts[${index}].mediaType`, "media type is not allowed by policy");
}

function requireWithin(root: string, candidate: string, index: number): void {
  const within = relative(root, candidate);
  if (within === ".." || within.startsWith(`..${sep}`) || isAbsolute(within)) fail(`artifacts[${index}].path`, "artifact escapes root");
}

async function hashHandle(handle: Awaited<ReturnType<typeof open>>, hash: ReturnType<typeof createHash>): Promise<number> {
  let total = 0;
  const buffer = Buffer.allocUnsafe(64 * 1024);
  for (;;) {
    const { bytesRead } = await handle.read(buffer, 0, buffer.byteLength, null);
    if (bytesRead === 0) return total;
    total += bytesRead;
    if (!Number.isSafeInteger(total)) throw new RangeError("artifact byte length exceeds safe range");
    hash.update(buffer.subarray(0, bytesRead));
  }
}

function createInspectionWindows(size: number): { prefix: Buffer; suffix: Buffer; suffixLength: number } {
  return { prefix: Buffer.alloc(size), suffix: Buffer.alloc(size), suffixLength: 0 };
}

async function readHandle(
  handle: Awaited<ReturnType<typeof open>>,
  hash: ReturnType<typeof createHash>,
  retained: Buffer | null,
  windows: { prefix: Buffer; suffix: Buffer; suffixLength: number }
): Promise<number> {
  let total = 0;
  const buffer = Buffer.allocUnsafe(64 * 1024);
  for (;;) {
    const { bytesRead } = await handle.read(buffer, 0, buffer.byteLength, null);
    if (bytesRead === 0) return total;
    const chunk = buffer.subarray(0, bytesRead);
    if (retained !== null) chunk.copy(retained, total);
    if (total < windows.prefix.byteLength) chunk.copy(windows.prefix, total, 0, Math.min(bytesRead, windows.prefix.byteLength - total));
    appendSuffix(windows, chunk);
    total += bytesRead;
    if (!Number.isSafeInteger(total)) throw new RangeError("artifact byte length exceeds safe range");
    hash.update(chunk);
  }
}

function appendSuffix(windows: { suffix: Buffer; suffixLength: number }, chunk: Buffer): void {
  const capacity = windows.suffix.byteLength;
  if (capacity === 0) return;
  if (chunk.byteLength >= capacity) {
    chunk.copy(windows.suffix, 0, chunk.byteLength - capacity);
    windows.suffixLength = capacity;
    return;
  }
  const overflow = Math.max(0, windows.suffixLength + chunk.byteLength - capacity);
  if (overflow > 0) {
    windows.suffix.copyWithin(0, overflow, windows.suffixLength);
    windows.suffixLength -= overflow;
  }
  chunk.copy(windows.suffix, windows.suffixLength);
  windows.suffixLength += chunk.byteLength;
}

function sameIdentity(left: BigIntStats, right: BigIntStats): boolean {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size &&
    left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
}

function fail(path: string, message: string): never {
  throw new CertificationValidationError(path, message);
}
