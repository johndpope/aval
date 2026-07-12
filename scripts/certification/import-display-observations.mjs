#!/usr/bin/env node
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { extname, resolve } from "node:path";

const STRUCTURED_EVIDENCE_LIMIT = 16 * 1024 * 1024;
const STRUCTURED_NODE_LIMIT = 1_000_000;

const [inputPath, metadataPath, outputPath] = process.argv.slice(2);
if (inputPath === undefined || metadataPath === undefined || outputPath === undefined) {
  throw new Error("usage: import-display-observations.mjs <samples.csv|samples.json> <metadata.json> <output.json>");
}

const certification = await import(resolve("packages/certification/dist/index.js"));
const metadataBytes = await boundedRead(metadataPath, 1024 * 1024, "display metadata");
const metadata = parseStrictJson(metadataBytes, "display metadata");
requireCanonical(metadataBytes, metadata, "display metadata");
if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata) || "samples" in metadata) throw new Error("display metadata must be an object without samples");
certification.validateDisplayCaptureLedger({ ...metadata, samples: [] });

const inputBytes = await boundedRead(inputPath, STRUCTURED_EVIDENCE_LIMIT, "display observations");
const samples = extname(inputPath).toLowerCase() === ".json"
  ? samplesFromJson(inputBytes, metadata)
  : samplesFromCsv(inputBytes);
const ledger = certification.validateDisplayCaptureLedger({ ...metadata, samples });
const outputBytes = certification.canonicalJsonBytes(ledger, {
  ...certification.DEFAULT_CANONICAL_LIMITS,
  maxNodes: STRUCTURED_NODE_LIMIT,
  maxBytes: STRUCTURED_EVIDENCE_LIMIT
});
await writeFile(outputPath, outputBytes, { flag: "wx" });
process.stdout.write(`${JSON.stringify({
  status: "imported",
  observations: ledger.samples.length,
  sha256: createHash("sha256").update(outputBytes).digest("hex")
})}\n`);

function samplesFromJson(bytes, expectedMetadata) {
  const input = parseStrictJson(bytes, "display observations JSON");
  requireCanonical(bytes, input, "display observations JSON");
  if (input === null || typeof input !== "object" || Array.isArray(input)) throw new Error("display observations JSON must be an object");
  const keys = Object.keys(input);
  if (keys.length === 1 && keys[0] === "samples") return input.samples;
  const full = certification.validateDisplayCaptureLedger(input);
  const { samples, ...metadata } = full;
  if (!sameCanonical(metadata, expectedMetadata)) throw new Error("display observations JSON metadata mismatch");
  return samples;
}

function samplesFromCsv(bytes) {
  const text = decodeUtf8(bytes, "display observations CSV");
  if (!text.endsWith("\n") || text.includes("\r") || /[^\x0a\x20-\x7e]/u.test(text)) throw new Error("display observations CSV must be terminal-LF canonical ASCII");
  let lineCount = 0;
  for (const character of text) if (character === "\n") lineCount += 1;
  if (lineCount < 2 || lineCount > 2_000_001) throw new Error("observation count is outside policy bounds");
  const lines = text.slice(0, -1).split("\n");
  const expected = certification.DISPLAY_CAPTURE_SAMPLE_KEYS;
  if (lines[0] !== expected.join(",")) throw new Error("observation CSV header is not canonical");
  return lines.slice(1).map((line, index) => parseCsvSample(line, index + 2, expected));
}

function parseCsvSample(line, lineNumber, expected) {
  const fields = line.split(",");
  if (fields.length !== expected.length) throw new Error(`line ${String(lineNumber)}: expected ${String(expected.length)} fields`);
  const result = {};
  for (let index = 0; index < expected.length; index += 1) {
    const key = expected[index];
    const value = fields[index];
    if (["markerAmbiguous", "blackDetected", "transparentUninitializedDetected"].includes(key)) {
      if (value !== "true" && value !== "false") throw new Error(`line ${String(lineNumber)}, ${key}: expected canonical boolean`);
      result[key] = value === "true";
      continue;
    }
    const nullable = ["contentValue", "contentComplement", "contentParity", "occurrenceValue", "occurrenceComplement", "occurrenceParity"].includes(key);
    if (value === "" && nullable) {
      result[key] = null;
      continue;
    }
    if (!/^(?:0|[1-9][0-9]*)$/u.test(value)) throw new Error(`line ${String(lineNumber)}, ${key}: expected canonical nonnegative integer`);
    const number = Number(value);
    if (!Number.isSafeInteger(number)) throw new Error(`line ${String(lineNumber)}, ${key}: integer is unsafe`);
    result[key] = number;
  }
  return result;
}

async function boundedRead(path, maximumBytes, label) {
  try { return await certification.readStableBoundedFile(path, maximumBytes); }
  catch (error) { throw new Error(`${label} failed stable bounded read`, { cause: error }); }
}

function parseStrictJson(bytes, label) {
  try {
    return JSON.parse(decodeUtf8(bytes, label));
  } catch (error) {
    throw new Error(`${label} is not strict JSON`, { cause: error });
  }
}

function decodeUtf8(bytes, label) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (error) {
    throw new Error(`${label} is not strict UTF-8`, { cause: error });
  }
}

function requireCanonical(bytes, value, label) {
  if (Buffer.compare(bytes, certification.canonicalJsonBytes(value, { ...certification.DEFAULT_CANONICAL_LIMITS, maxNodes: STRUCTURED_NODE_LIMIT, maxBytes: STRUCTURED_EVIDENCE_LIMIT })) !== 0) throw new Error(`${label} is not canonical JSON`);
}

function sameCanonical(left, right) {
  return Buffer.compare(certification.canonicalJsonBytes(left), certification.canonicalJsonBytes(right)) === 0;
}
