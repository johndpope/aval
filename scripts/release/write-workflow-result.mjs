#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const args = parse(process.argv.slice(2));
const output = resolve(required(args, "output"));
const status = requiredEnv("WORKFLOW_JOB_STATUS");
if (!new Set(["success", "failure", "cancelled", "skipped"]).has(status)) throw new Error("workflow job status is invalid");
const runId = requiredEnv("GITHUB_RUN_ID");
const runAttempt = requiredEnv("GITHUB_RUN_ATTEMPT");
const commit = requiredEnv("GITHUB_SHA");
if (!/^[1-9][0-9]{0,19}$/u.test(runId) || !/^[1-9][0-9]{0,9}$/u.test(runAttempt) || !/^[0-9a-f]{40}$/u.test(commit)) throw new Error("workflow result identity is invalid");
const document = {
  schemaVersion: "1.0",
  workflow: requiredEnv("GITHUB_WORKFLOW"),
  job: required(args, "job"),
  status,
  runId,
  runAttempt,
  commit
};
for (const value of [document.workflow, document.job]) if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$/u.test(value)) throw new Error("workflow result label is invalid");
await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(document)}\n`, { flag: "wx", mode: 0o444 });
process.stdout.write(`${JSON.stringify({ status: "passed", output })}\n`);

function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) { const key = values[index]; if (!key?.startsWith("--")) throw new Error(`invalid argument ${String(key)}`); result[key.slice(2)] = values[index + 1] ?? "true"; } return result; }
function required(values, key) { const value = values[key]; if (typeof value !== "string" || value.length < 1 || value.length > 256) throw new Error(`--${key} is required`); return value; }
function requiredEnv(key) { const value = process.env[key]; if (typeof value !== "string" || value.length < 1 || value.length > 256 || /[\u0000-\u001F\u007F]/u.test(value)) throw new Error(`${key} is invalid`); return value; }
