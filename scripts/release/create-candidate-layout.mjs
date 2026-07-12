#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstat, readdir, realpath, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";

import { candidateRoleForPath, readVerifiedRegularFile } from "./candidate-artifacts.mjs";

const args = parse(process.argv.slice(2));
const root = await realpath(resolve(required(args, "root")));
const output = resolve(required(args, "output"));
const commit = git("rev-parse", "HEAD");
const tree = git("rev-parse", "HEAD^{tree}");
const status = git("status", "--porcelain");
if (status !== "") throw new Error("candidate layout requires a clean immutable source tree");
const files = [];
await collect(root, root, files);
files.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
await verifyCommittedSourceCoverage(files, commit);
const coverage = Object.fromEntries(["schema", "fixture", "documentation", "example", "browser-harness"].map((role) => [role, files.filter((entry) => entry.role === role).map(({ path }) => path)]));
for (const [role, paths] of Object.entries(coverage)) if (paths.length === 0) throw new Error(`candidate layout has no ${role} files`);
const layout = { schemaVersion: "1.0", releaseVersion: "1.0.0", commit, tree, files, coverage };
await writeFile(output, `${JSON.stringify(layout, null, 2)}\n`, { flag: "wx", mode: 0o444 });
process.stdout.write(`${JSON.stringify({ status: "passed", output, commit, tree, files: files.length })}\n`);

async function collect(candidateRoot, directory, outputFiles) {
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
    const path = join(directory, entry.name);
    const relativePath = relative(candidateRoot, path).split(sep).join("/");
    if (relativePath === "candidate-layout.json" || relativePath === "candidate-manifest.json") continue;
    if (entry.isSymbolicLink()) throw new Error(`candidate layout rejects symlink: ${relativePath}`);
    if (entry.isDirectory()) await collect(candidateRoot, path, outputFiles);
    else if (entry.isFile()) {
      const bytes = await readVerifiedRegularFile(relativePath, candidateRoot);
      outputFiles.push({ path: relativePath, role: candidateRoleForPath(relativePath), sha256: createHash("sha256").update(bytes).digest("hex"), byteLength: bytes.byteLength });
    } else throw new Error(`candidate layout rejects special entry: ${relativePath}`);
  }
}

async function verifyCommittedSourceCoverage(files, commit) {
  const staged = new Set(files.map(({ path }) => path));
  const tracked = git("ls-tree", "-r", "--name-only", commit, "--", "etc/api", "schemas", "config/release", "fixtures", "docs", "examples")
    .split("\n").filter(Boolean).filter((path) => path !== "docs/releases/1.0.0.md" && path !== "docs/certification/1.0.0" && !path.startsWith("docs/certification/1.0.0/"));
  for (const path of tracked) if (!staged.has(path)) throw new Error(`candidate staging omitted committed source file: ${path}`);
  for (const { path } of files) if (/^(?:etc\/api|schemas|config\/release|fixtures|docs|examples)\//u.test(path) && !tracked.includes(path)) throw new Error(`candidate staging contains an uncommitted source file: ${path}`);
}

function git(...values) { const result = spawnSync("git", values, { encoding: "utf8" }); if (result.status !== 0) throw new Error(result.stderr || "git command failed"); return result.stdout.trim(); }
function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) { const key = values[index]; if (!key?.startsWith("--")) throw new Error(`invalid argument ${String(key)}`); result[key.slice(2)] = values[index + 1] ?? "true"; } return result; }
function required(values, key) { const value = values[key]; if (typeof value !== "string" || value.length < 1) throw new Error(`--${key} is required`); return value; }
