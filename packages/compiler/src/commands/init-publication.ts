import { lstat, mkdir, open, rename, rmdir } from "node:fs/promises";
import { dirname } from "node:path";

import { CompilerError } from "../diagnostics.js";
import { syncDirectory } from "../compile/output.js";

interface DirectoryIdentity {
  readonly device: string;
  readonly inode: string;
}

/**
 * Publish a completely staged directory without replacing an independently
 * created target. POSIX needs an atomic directory claim because rename(2) may
 * replace an existing empty directory; Windows directory rename already fails
 * when the destination exists.
 */
export async function publishStagedDirectoryNoReplace(
  staged: string,
  target: string,
  platform: NodeJS.Platform = process.platform,
  syncParent: (path: string) => Promise<void> = syncDirectory
): Promise<void> {
  const parent = dirname(target);
  if (platform === "win32") {
    let committed = false;
    try {
      await rename(staged, target);
      committed = true;
      await syncParent(parent);
      return;
    } catch (error) {
      if (committed) throw durabilityUncertain(target, error);
      throw new CompilerError("IO_FAILED", "Init path changed before publication", {
        path: target,
        cause: error
      });
    }
  }

  let reservation: DirectoryIdentity | undefined;
  let committed = false;
  try {
    // mkdir is the cooperative no-replace claim exposed by Node's filesystem
    // API. An independently created destination that wins before this call
    // produces EEXIST and is never renamed over. Same-user namespace mutation
    // remains outside the process-isolation boundary, as it does after commit.
    await mkdir(target, { mode: 0o700 });
    reservation = await directoryIdentity(target);
    await syncParent(parent);
    await assertDirectoryIdentity(target, reservation);
    await rename(staged, target);
    committed = true;
    await syncParent(parent);
  } catch (error) {
    if (committed) throw durabilityUncertain(target, error);
    if (reservation !== undefined) {
      await removeOwnedEmptyReservation(target, reservation).catch(() => undefined);
      await syncParent(parent).catch(() => undefined);
    }
    if (error instanceof CompilerError) throw error;
    throw new CompilerError("IO_FAILED", "Init path changed before publication", {
      path: target,
      cause: error
    });
  }
}

function durabilityUncertain(path: string, cause: unknown): CompilerError {
  return new CompilerError(
    "IO_FAILED",
    "Init project was committed but directory durability could not be confirmed",
    {
      path,
      cause,
      committed: true,
      hint: "The complete project is present; inspect it before retrying at another path."
    }
  );
}

async function directoryIdentity(path: string): Promise<DirectoryIdentity> {
  const handle = await open(path, "r");
  try {
    const metadata = await handle.stat({ bigint: true });
    if (!metadata.isDirectory()) throw new Error("reservation is not a directory");
    return Object.freeze({ device: String(metadata.dev), inode: String(metadata.ino) });
  } finally {
    await handle.close();
  }
}

async function assertDirectoryIdentity(
  path: string,
  expected: DirectoryIdentity
): Promise<void> {
  const metadata = await lstat(path, { bigint: true });
  if (
    !metadata.isDirectory() ||
    metadata.isSymbolicLink() ||
    String(metadata.dev) !== expected.device ||
    String(metadata.ino) !== expected.inode
  ) {
    throw new CompilerError("IO_FAILED", "Init directory reservation changed", {
      path
    });
  }
}

async function removeOwnedEmptyReservation(
  path: string,
  expected: DirectoryIdentity
): Promise<void> {
  const metadata = await lstat(path, { bigint: true }).catch(
    (error: NodeJS.ErrnoException) => error.code === "ENOENT" ? undefined : Promise.reject(error)
  );
  if (
    metadata === undefined ||
    !metadata.isDirectory() ||
    metadata.isSymbolicLink() ||
    String(metadata.dev) !== expected.device ||
    String(metadata.ino) !== expected.inode
  ) return;
  await rmdir(path);
}
