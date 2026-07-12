#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const args = parseArguments(process.argv.slice(2));
const inputPath = required(args, "input");
const outputPath = required(args, "output");
const input = JSON.parse(await readFile(inputPath, "utf8"));
rejectPrivateData(input, "$input");
for (const field of ["environment", "operatorRole", "candidateManifestDigest", "fixtureDigest", "harnessDigest"]) {
  if (input[field] === undefined) throw new Error(`${field} is required`);
}
if (!/^[0-9a-f]{64}$/u.test(input.candidateManifestDigest) || !/^[0-9a-f]{64}$/u.test(input.fixtureDigest) || !/^[0-9a-f]{64}$/u.test(input.harnessDigest)) throw new Error("run-config digests must be lowercase SHA-256");
const certification = await import(new URL("../../packages/certification/dist/index.js", import.meta.url));
const environment = certification.validateRuntimeEnvironment(input.environment);
if (typeof input.operatorRole !== "string" || input.operatorRole.length < 1 || input.operatorRole.length > 128) throw new Error("operatorRole is invalid");
const normalized = deepSort({ schemaVersion: "1.0", createdAt: new Date().toISOString(), ...input, environment });
const canonical = `${JSON.stringify(normalized)}\n`;
const configDigest = createHash("sha256").update(canonical).digest("hex");
await writeFile(outputPath, canonical, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ output: outputPath, configDigest })}\n`);

function rejectPrivateData(value, path) {
  if (typeof value === "string") {
    if (/^(?:\/|[A-Za-z]:[\\/]|~[\\/])/u.test(value)) throw new Error(`${path}: local path is forbidden`);
    if (/https?:\/\/[^\s?]+\?[^\s]+/iu.test(value)) throw new Error(`${path}: URL query is forbidden`);
    return;
  }
  if (Array.isArray(value)) return value.forEach((item, index) => rejectPrivateData(item, `${path}[${index}]`));
  if (value !== null && typeof value === "object") for (const [key, item] of Object.entries(value)) {
    if (/serial|user(?:name)?|profilePath/iu.test(key)) throw new Error(`${path}.${key}: personal or serial field is forbidden`);
    rejectPrivateData(item, `${path}.${key}`);
  }
}
function deepSort(value) {
  if (Array.isArray(value)) return value.map(deepSort);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, deepSort(value[key])]));
  return value;
}
function parseArguments(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 2) result[String(values[index]).replace(/^--/u, "")] = values[index + 1];
  return result;
}
function required(values, key) { if (values[key] === undefined) throw new Error(`--${key} is required`); return values[key]; }
