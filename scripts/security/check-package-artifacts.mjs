#!/usr/bin/env node
import { readFile, readdir, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const roots = process.argv.slice(2);
if (roots.length === 0) throw new Error("usage: check-package-artifacts.mjs <file-or-directory> [...]");
const failures = [];
for (const root of roots) await scan(resolve(root));
if (failures.length > 0) throw new Error(failures.join("\n"));
process.stdout.write(`${JSON.stringify({ status: "passed", roots: roots.length })}\n`);

async function scan(path) {
  const info = await stat(path);
  if (info.isDirectory()) {
    for (const entry of await readdir(path)) await scan(join(path, entry));
    return;
  }
  if (!info.isFile() || info.size > 64 * 1024 * 1024) return;
  if (path.endsWith(".tgz")) {
    const listing = spawnSync("tar", ["-tzf", path], { encoding: "utf8", timeout: 30_000, maxBuffer: 4 * 1024 * 1024 });
    if (listing.status !== 0) { failures.push(`${path}: unreadable archive`); return; }
    const names = listing.stdout.trim().split("\n").filter(Boolean);
    if (names.length > 10_000) { failures.push(`${path}: archive entry limit exceeded`); return; }
    for (const name of names) {
      if (/(?:^|\/)(?:ffmpeg|ffprobe|libx264)(?:\.exe|\.dll|\.dylib|\.so)?$/iu.test(name)) failures.push(`${path}:${name}: bundled native codec/tool`);
      if (/\.(?:js|json|d\.ts|md|txt)$/u.test(name)) {
        const extracted = spawnSync("tar", ["-xOzf", path, name], { encoding: null, timeout: 30_000, maxBuffer: 16 * 1024 * 1024 });
        if (extracted.status !== 0) failures.push(`${path}:${name}: could not inspect entry`);
        else scanBytes(extracted.stdout, `${path}:${name}`);
      }
    }
    return;
  }
  const bytes = await readFile(path);
  scanBytes(bytes, path);
}
function scanBytes(bytes, path) {
  if (bytes.includes(Buffer.from("BEGIN PRIVATE KEY")) || bytes.includes(Buffer.from("BEGIN RSA PRIVATE KEY"))) failures.push(`${path}: private key material`);
  if (bytes.includes(Buffer.from("/Users/")) || bytes.includes(Buffer.from("/home/"))) failures.push(`${path}: local absolute path`);
  const text = bytes.toString("utf8");
  if (/https?:\/\/[^\s"']+\?(?:token|key|signature|authorization)=/iu.test(text)) failures.push(`${path}: secret-bearing URL query`);
  if (/(?:^|\/)(?:ffmpeg|ffprobe|libx264)(?:\.exe|\.dll|\.dylib|\.so)?$/iu.test(path)) failures.push(`${path}: bundled native codec/tool`);
}
