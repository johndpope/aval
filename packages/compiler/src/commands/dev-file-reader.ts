import type { Stats } from "node:fs";
import { lstat, open, realpath, type FileHandle } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";

export interface BoundedReadAdmission {
  tryAcquire(): (() => void) | null;
}

export type OpenedFileRead =
  | Readonly<{ status: "ok"; bytes: Buffer }>
  | Readonly<{ status: "missing" }>
  | Readonly<{ status: "too-large" }>
  | Readonly<{ status: "changing" }>;

export type BoundedFileRead = OpenedFileRead | Readonly<{ status: "busy" }>;

export interface ReadOpenedFileHooks {
  /** @internal Deterministic test seam for an edit after the authoritative open-time stat. */
  readonly afterInitialStat?: () => Promise<void>;
}

interface PathContainmentOperations {
  readonly resolve: typeof resolve;
  readonly relative: typeof relative;
  readonly isAbsolute: typeof isAbsolute;
  readonly sep: string;
}

/** @internal Test seam for the dev server's non-queuing file-read bound. */
export function createBoundedReadAdmission(limit: number): BoundedReadAdmission {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 64) throw new TypeError("file-read concurrency limit must be from 1 through 64");
  let active = 0;
  return Object.freeze({
    tryAcquire(): (() => void) | null {
      if (active >= limit) return null;
      active += 1;
      let released = false;
      return (): void => {
        if (released) return;
        released = true;
        active -= 1;
      };
    }
  });
}

export async function readBoundedFile(
  path: string,
  maximumBytes: number,
  admission: BoundedReadAdmission,
  containmentRoot?: string
): Promise<BoundedFileRead> {
  const release = admission.tryAcquire();
  if (release === null) return Object.freeze({ status: "busy" });
  try {
    return await readOpenedFile(path, maximumBytes, containmentRoot);
  } finally {
    release();
  }
}

export async function readOpenedFile(
  path: string,
  maximumBytes: number,
  containmentRoot?: string,
  hooks: ReadOpenedFileHooks = {}
): Promise<OpenedFileRead> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 0) throw new TypeError("file byte limit must be a nonnegative safe integer");
  let handle: FileHandle;
  try {
    handle = await open(path, "r");
  } catch {
    return Object.freeze({ status: "missing" });
  }
  try {
    const before = await handle.stat();
    if (!before.isFile()) return Object.freeze({ status: "missing" });
    if (containmentRoot !== undefined && !await openedFileMatchesContainedPath(path, containmentRoot, before)) return Object.freeze({ status: "missing" });
    if (!Number.isSafeInteger(before.size) || before.size < 0 || before.size > maximumBytes) return Object.freeze({ status: "too-large" });
    await hooks.afterInitialStat?.();
    const bytes = Buffer.allocUnsafe(before.size);
    let offset = 0;
    while (offset < bytes.byteLength) {
      const result = await handle.read(bytes, offset, bytes.byteLength - offset, offset);
      if (result.bytesRead === 0) return Object.freeze({ status: "changing" });
      offset += result.bytesRead;
    }
    const after = await handle.stat();
    if (!sameStableFile(before, after) || (containmentRoot !== undefined && !await openedFileMatchesContainedPath(path, containmentRoot, after))) return Object.freeze({ status: "changing" });
    return Object.freeze({ status: "ok", bytes });
  } catch {
    return Object.freeze({ status: "changing" });
  } finally {
    await handle.close().catch(() => undefined);
  }
}

/** @internal Test seam for platform-independent module-root containment. */
export function isResolvedPathWithinRoot(
  root: string,
  candidate: string,
  operations: PathContainmentOperations = { resolve, relative, isAbsolute, sep }
): boolean {
  const relativePath = operations.relative(operations.resolve(root), operations.resolve(candidate));
  return relativePath !== "" && relativePath !== ".." && !relativePath.startsWith(`..${operations.sep}`) && !operations.isAbsolute(relativePath);
}

/** Resolve a regular file and prove its canonical path remains below the canonical root. */
export async function resolveRealPathWithinRoot(root: string, candidate: string): Promise<string | null> {
  try {
    const [canonicalRoot, canonicalCandidate] = await Promise.all([realpath(root), realpath(candidate)]);
    const candidateStats = await lstat(canonicalCandidate);
    return candidateStats.isFile() && isResolvedPathWithinRoot(canonicalRoot, canonicalCandidate) ? canonicalCandidate : null;
  } catch {
    return null;
  }
}

function sameStableFile(before: Stats, after: Stats): boolean {
  return after.size === before.size && after.dev === before.dev && after.ino === before.ino && after.mtimeMs === before.mtimeMs && after.ctimeMs === before.ctimeMs;
}

async function openedFileMatchesContainedPath(path: string, root: string, opened: Stats): Promise<boolean> {
  try {
    const [canonicalRoot, canonicalPath, pathStats] = await Promise.all([realpath(root), realpath(path), lstat(path)]);
    return pathStats.isFile() && pathStats.dev === opened.dev && pathStats.ino === opened.ino && isResolvedPathWithinRoot(canonicalRoot, canonicalPath);
  } catch {
    return false;
  }
}
