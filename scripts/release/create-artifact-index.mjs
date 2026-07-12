#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstat, readdir, writeFile } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";

import { candidateArtifactId, candidateRoleForPath, mediaType, readVerifiedRegularFile } from "./candidate-artifacts.mjs";

const root = process.cwd();
const values = process.argv.slice(2);
const outputIndex = values.indexOf("--output");
const output = values[outputIndex + 1];
if (outputIndex < 0 || output === undefined) throw new Error("--output is required");
const pathRootIndex = values.indexOf("--path-root");
const artifactPathRoot = pathRootIndex < 0 ? root : resolve(root, values[pathRootIndex + 1] ?? "");
const includes = [];
const excludedPrefixes = [];
for (let index = 0; index < values.length; index += 1) if (values[index] === "--include") {
  const entry = values[index + 1];
  if (entry === undefined || !entry.includes(":")) throw new Error("--include requires role:path");
  includes.push(entry);
} else if (values[index] === "--exclude") {
  const entry = values[index + 1];
  if (entry === undefined || entry.startsWith("/") || entry.includes("\\") || entry.split("/").includes("..")) throw new Error("--exclude requires a safe repository-relative prefix");
  excludedPrefixes.push(entry.replace(/\/$/u, ""));
}
if (includes.length === 0 || includes.length > 64) throw new Error("one to 64 include roots are required");
const artifacts = [];
for (const entry of includes) {
  const split = entry.indexOf(":");
  const role = entry.slice(0, split);
  const path = entry.slice(split + 1);
  if (!/^[a-z][a-z0-9-]{0,63}$/u.test(role)) throw new Error(`invalid artifact role: ${role}`);
  await collect(resolve(root, path), role, artifacts);
}
artifacts.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
if (artifacts.length === 0 || artifacts.length > 4096) throw new Error("artifact count is outside policy bounds");
const seen = new Set();
const seenIds = new Set();
for (const artifact of artifacts) {
  if (seen.has(artifact.path)) throw new Error(`duplicate artifact path: ${artifact.path}`);
  if (seenIds.has(artifact.id)) throw new Error(`duplicate artifact ID: ${artifact.id}`);
  seen.add(artifact.path);
  seenIds.add(artifact.id);
}
await writeFile(output, `${JSON.stringify({ schemaVersion: "1.0", artifacts }, null, 2)}\n`, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ status: "passed", output, artifacts: artifacts.length })}\n`);

async function collect(path, role, output) {
  const repositoryRelative = relative(artifactPathRoot, path).split(sep).join("/");
  if (excludedPrefixes.some((prefix) => repositoryRelative === prefix || repositoryRelative.startsWith(`${prefix}/`))) return;
  const info = await lstat(path);
  if (info.isSymbolicLink()) throw new Error(`artifact symlink is forbidden: ${path}`);
  if (info.isDirectory()) {
    for (const entry of await readdir(path)) await collect(join(path, entry), role, output);
    return;
  }
  if (!info.isFile()) throw new Error(`artifact is not a regular file: ${path}`);
  const relativePath = repositoryRelative;
  if (relativePath.startsWith("../") || relativePath === "candidate-manifest.json" || relativePath.endsWith("/candidate-manifest.json") || relativePath.endsWith("/release-manifest.json")) throw new Error(`unsafe or recursive artifact path: ${relativePath}`);
  const bytes = await readVerifiedRegularFile(relativePath, artifactPathRoot);
  const identity = { sha256: createHash("sha256").update(bytes).digest("hex"), byteLength: bytes.byteLength };
  const effectiveRole = role === "candidate" ? candidateRoleForPath(relativePath) : role;
  output.push({
    id: candidateArtifactId(relativePath),
    role: effectiveRole,
    path: relativePath,
    sha256: identity.sha256,
    byteLength: identity.byteLength,
    mediaType: mediaType(relativePath)
  });
}
