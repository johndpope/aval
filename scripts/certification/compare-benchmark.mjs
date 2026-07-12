#!/usr/bin/env node
import { readFile } from "node:fs/promises";

const [currentPath, baselinePath] = process.argv.slice(2);
if (currentPath === undefined || baselinePath === undefined) throw new Error("usage: compare-benchmark.mjs <current.json> <baseline.json>");
const [current, baseline] = await Promise.all([currentPath, baselinePath].map(async (path) => JSON.parse(await readFile(path, "utf8"))));
if (current.profileId !== baseline.profileId || current.metric !== baseline.metric || current.unit !== baseline.unit) throw new Error("benchmark profiles, metrics, and units must match");
for (const value of [current.statistics?.median, baseline.statistics?.median]) if (!Number.isFinite(value)) throw new Error("benchmark median must be finite");
const ratioMillionths = Math.round(current.statistics.median * 1_000_000 / baseline.statistics.median);
process.stdout.write(`${JSON.stringify({ status: "advisory", ratioMillionths, reviewRequired: ratioMillionths > 1_100_000 })}\n`);
