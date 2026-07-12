#!/usr/bin/env node
import { constants as fsConstants } from "node:fs";
import { open, lstat, mkdir, readdir } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

const root = process.cwd();
const args = parse(process.argv.slice(2));
const output = resolve(root, args.output ?? "artifacts/1.0.0/candidate");
const mappings = args.map ?? defaultMappings();
if (!Array.isArray(mappings) || mappings.length < 1 || mappings.length > 64) throw new RangeError("candidate staging requires one to 64 mappings");
await mkdir(output);
for (const mapping of mappings) {
  const split = mapping.indexOf(":");
  if (split < 1) throw new TypeError(`invalid candidate mapping: ${mapping}`);
  const source = resolve(root, mapping.slice(0, split));
  const destinationText = mapping.slice(split + 1);
  if (destinationText.startsWith("/") || destinationText.includes("\\") || (destinationText !== "" && destinationText.split("/").some((part) => part === "" || part === ".." || part === "."))) throw new TypeError(`unsafe candidate destination: ${destinationText}`);
  const destination = resolve(output, destinationText);
  requireWithin(output, destination);
  await copyTree(source, destination, mapping.slice(0, split));
}
process.stdout.write(`${JSON.stringify({ status: "passed", output: relative(root, output).split(sep).join("/") })}\n`);

async function copyTree(source, destination, repositoryPath) {
  if (excluded(repositoryPath)) return;
  const info = await lstat(source);
  if (info.isSymbolicLink()) throw new Error(`candidate source symlink is forbidden: ${repositoryPath}`);
  if (info.isDirectory()) {
    await mkdir(destination, { recursive: true });
    for (const name of (await readdir(source)).sort()) {
      await copyTree(join(source, name), join(destination, name), `${repositoryPath}/${name}`);
    }
    return;
  }
  if (!info.isFile()) throw new Error(`candidate source is not a regular file: ${repositoryPath}`);
  if (info.size > 1024 * 1024 * 1024) throw new Error(`candidate source exceeds byte policy: ${repositoryPath}`);
  const noFollow = fsConstants.O_NOFOLLOW ?? 0;
  const sourceHandle = await open(source, fsConstants.O_RDONLY | noFollow);
  let destinationHandle;
  try {
    const before = await sourceHandle.stat();
    if (!before.isFile() || before.dev !== info.dev || before.ino !== info.ino || before.size !== info.size) throw new Error(`candidate source changed before copy: ${repositoryPath}`);
    const bytes = await sourceHandle.readFile();
    const after = await sourceHandle.stat();
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size || bytes.byteLength !== before.size) throw new Error(`candidate source changed during copy: ${repositoryPath}`);
    await mkdir(dirname(destination), { recursive: true });
    destinationHandle = await open(destination, fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL, 0o444);
    await destinationHandle.writeFile(bytes);
    await destinationHandle.sync();
  } finally {
    await destinationHandle?.close();
    await sourceHandle.close();
  }
}

function excluded(path) {
  const normalized = path.replaceAll("\\", "/");
  return normalized === "docs/certification/1.0.0" || normalized.startsWith("docs/certification/1.0.0/") ||
    normalized === "docs/releases/1.0.0.md";
}

function requireWithin(parent, child) {
  const within = relative(parent, child);
  if (within === ".." || within.startsWith(`..${sep}`)) throw new Error("candidate destination escapes staging root");
}

function defaultMappings() {
  return [
    "artifacts/1.0.0/packages:packages",
    "artifacts/1.0.0/package-index.json:package-index.json",
    "artifacts/1.0.0/package-inspection.json:package-inspection.json",
    "artifacts/1.0.0/sbom:sbom",
    "artifacts/1.0.0/license-report.json:license-report.json",
    "etc/api:etc/api",
    "schemas:schemas",
    "config/release:config/release",
    "fixtures:fixtures",
    "docs:docs",
    "examples:examples",
    "apps/playground/dist:",
    "README.md:README.md",
    "LICENSE:LICENSE",
    "SECURITY.md:SECURITY.md",
    "THREAT-MODEL.md:THREAT-MODEL.md",
    "THIRD_PARTY_NOTICES.md:THIRD_PARTY_NOTICES.md",
    "package-lock.json:package-lock.json"
  ];
}

function parse(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    if (key === "--map") {
      (result.map ??= []).push(values[++index]);
    } else if (key === "--output") result.output = values[++index];
    else throw new TypeError(`unknown argument: ${key}`);
  }
  return result;
}
