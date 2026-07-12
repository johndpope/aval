#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile, readdir, lstat } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export async function hashFileList(root) {
  const absoluteRoot = resolve(root);
  const entries = [];
  await visit(absoluteRoot, absoluteRoot, entries);
  const canonical = `${JSON.stringify(entries.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0))}\n`;
  return {
    entries,
    sha256: createHash("sha256").update(canonical).digest("hex")
  };
}

async function visit(root, directory, entries) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const name = relative(root, path).split("\\").join("/");
    if (entry.isSymbolicLink()) throw new Error(`symbolic link is forbidden: ${name}`);
    if (entry.isDirectory()) await visit(root, path, entries);
    else if (entry.isFile()) {
      const [bytes, status] = await Promise.all([readFile(path), lstat(path)]);
      entries.push({
        path: name,
        byteLength: bytes.byteLength,
        mode: status.mode & 0o777,
        sha256: createHash("sha256").update(bytes).digest("hex")
      });
    }
  }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2];
  if (root === undefined) throw new Error("usage: hash-file-list.mjs <directory>");
  process.stdout.write(`${JSON.stringify(await hashFileList(root), null, 2)}\n`);
}
