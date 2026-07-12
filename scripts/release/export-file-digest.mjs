#!/usr/bin/env node
import { appendFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { basename, dirname, resolve } from "node:path";

import { readVerifiedRegularFile } from "./candidate-artifacts.mjs";

const args = parse(process.argv.slice(2));
const path = resolve(required(args, "path"));
const key = required(args, "key");
if (!/^[a-z][a-z0-9_]{0,63}$/u.test(key)) throw new Error("GitHub output key is invalid");
const bytes = await readVerifiedRegularFile(basename(path), dirname(path), 1024 * 1024);
const digest = createHash("sha256").update(bytes).digest("hex");
const output = process.env.GITHUB_OUTPUT;
if (typeof output !== "string" || output.length < 1) throw new Error("GITHUB_OUTPUT is unavailable");
await appendFile(output, `${key}=${digest}\n`, { encoding: "utf8" });
process.stdout.write(`${JSON.stringify({ status: "passed", path, key, digest })}\n`);

function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) { const key = values[index]; if (!key?.startsWith("--")) throw new Error(`invalid argument ${String(key)}`); result[key.slice(2)] = values[index + 1] ?? "true"; } return result; }
function required(values, key) { const value = values[key]; if (typeof value !== "string" || value.length < 1) throw new Error(`--${key} is required`); return value; }
