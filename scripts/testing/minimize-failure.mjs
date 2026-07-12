#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

const [inputPath, command, ...args] = process.argv.slice(2);
if (inputPath === undefined || command === undefined) throw new Error("usage: minimize-failure.mjs <json-array> <command> [...args]");
const input = JSON.parse(await readFile(inputPath, "utf8"));
if (!Array.isArray(input) || input.length > 100_000) throw new Error("input must be a bounded JSON array");
let candidate = input;
let steps = 0;
for (let width = Math.ceil(candidate.length / 2); width >= 1 && steps < 1_000; width = Math.floor(width / 2)) {
  for (let start = 0; start < candidate.length && steps < 1_000; start += width) {
    steps += 1;
    const next = [...candidate.slice(0, start), ...candidate.slice(start + width)];
    const result = spawnSync(command, args, { input: `${JSON.stringify(next)}\n`, encoding: "utf8", timeout: 10_000, maxBuffer: 1024 * 1024 });
    if (result.status !== 0) {
      candidate = next;
      break;
    }
  }
}
const serialized = `${JSON.stringify(candidate)}\n`;
process.stdout.write(`${JSON.stringify({ generatorVersion: "bounded-ddmin-v1", steps, itemCount: candidate.length, sha256: createHash("sha256").update(serialized).digest("hex"), minimized: candidate }, null, 2)}\n`);
