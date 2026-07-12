#!/usr/bin/env node
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { reconstructReportIndex } from "./report-index-reconstruction.mjs";
import { collectSelfContainedReportSet } from "../release/release-report-set.mjs";

const args = parse(process.argv.slice(2));
const indexPath = required(args, "index");
const certification = await import(resolve("packages/certification/dist/index.js"));
const policy = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await certification.readStableBoundedFile("config/release/release-policy.json", 1024 * 1024)));
const referenceRoot = resolve(args["path-root"] ?? process.cwd());
const candidatePath = args.candidate === undefined ? undefined : resolve(args.candidate);
const result = await reconstructReportIndex({ indexPath, candidatePath, referenceRoot, certification, policy });
const indexDigest = createHash("sha256").update(result.indexBytes).digest("hex");
if (args["expected-index-digest"] !== undefined && args["expected-index-digest"] !== indexDigest) throw new Error("report index digest does not match protected intent");
if (args["expected-candidate-digest"] !== undefined && args["expected-candidate-digest"] !== result.candidateDigest) throw new Error("report candidate digest does not match protected intent");
const requirePassed = booleanFlag(args, "require-passed");
if (requirePassed && (result.index.releaseStatus !== "passed" || result.index.runtimeScheduling !== "passed")) throw new Error("report index has not passed the exact release gate");
if (requirePassed) certification.assertApprovedReviews(result.index.reviews);
const requireClosedRoot = booleanFlag(args, "require-closed-root");
if (requireClosedRoot) {
  await collectSelfContainedReportSet({
    index: result.index,
    indexBytes: result.indexBytes,
    indexPath: resolve(indexPath),
    referenceRoot,
    releaseRoot: referenceRoot
  });
}
process.stdout.write(`${JSON.stringify({ status: "passed", releaseStatus: result.index.releaseStatus, profiles: result.profiles.length, candidateManifestDigest: result.candidateDigest, indexDigest, closedRoot: requireClosedRoot })}\n`);
function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) result[String(values[index]).replace(/^--/u, "")] = values[index + 1]; return result; }
function required(values, key) { if (values[key] === undefined) throw new Error(`--${key} is required`); return values[key]; }
function booleanFlag(values, key) { const value = values[key]; if (value === undefined || value === "false") return false; if (value === "true") return true; throw new Error(`--${key} must be true or false`); }
