#!/usr/bin/env node
import { access, chmod, lstat, readFile, readdir } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { validateApprovedPublicationMetadata } from "./publication-metadata.mjs";
import { validateApprovedLegalReview } from "./candidate-root.mjs";
import { prepareImmutableCandidateOutput } from "./immutable-candidate-output.mjs";

const outputRoot = "artifacts/1.0.0";
const candidateRoot = `${outputRoot}/candidate`;
const legalReview = JSON.parse(await readFile("config/release/legal-review.json", "utf8"));
validateApprovedLegalReview(legalReview);
validateApprovedPublicationMetadata(JSON.parse(await readFile("config/release/publication-metadata.json", "utf8")));
for (const required of [`${outputRoot}/packages`, `${outputRoot}/package-index.json`, `${outputRoot}/package-inspection.json`, `${outputRoot}/sbom`, `${outputRoot}/license-report.json`, "etc/api", "schemas", "fixtures", "docs", "examples", "apps/playground/dist"]) await access(required);
const prepared = await prepareImmutableCandidateOutput({ candidate: candidateRoot, legacyIndex: `${outputRoot}/artifact-index.json` });
let sealed = false;
try {
  run(process.execPath, ["scripts/release/stage-candidate.mjs", "--output", prepared.stagedCandidate]);
  run(process.execPath, ["scripts/release/create-candidate-layout.mjs", "--root", prepared.stagedCandidate, "--output", `${prepared.stagedCandidate}/candidate-layout.json`]);
  run(process.execPath, [
    "scripts/release/create-artifact-index.mjs",
    "--output", prepared.temporaryIndex,
    "--path-root", prepared.stagedCandidate,
    "--include", `candidate:${prepared.stagedCandidate}`
  ]);
  const created = JSON.parse(run(process.execPath, [
    "scripts/release/create-manifest.mjs",
    "--artifacts", prepared.temporaryIndex,
    "--root", prepared.stagedCandidate,
    "--output", `${prepared.stagedCandidate}/candidate-manifest.json`
  ], true));
  if (typeof created.sha256 !== "string" || !/^[0-9a-f]{64}$/u.test(created.sha256)) throw new Error("candidate manifest creator returned an invalid digest");
  run(process.execPath, [
    "scripts/release/verify-manifest.mjs",
    "--candidate", `${prepared.stagedCandidate}/candidate-manifest.json`,
    "--expected-candidate-digest", created.sha256,
    "--verify-environment", "true"
  ]);
  await sealTree(prepared.stagedCandidate);
  sealed = true;
  await prepared.publish();
  sealed = false;
  process.stdout.write(`${JSON.stringify({ status: "passed", candidate: resolve(prepared.finalCandidate), candidateManifestDigest: created.sha256 })}\n`);
} finally {
  if (sealed) await makeWritable(prepared.stagedCandidate).catch(() => undefined);
  await prepared.dispose();
}

function run(command, args, capture = false) {
  const result = spawnSync(command, args, { encoding: capture ? "utf8" : undefined, stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit", timeout: 5 * 60_000 });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) throw new Error(capture ? result.stderr || result.stdout || `${command} failed` : `${command} ${args.join(" ")} failed`);
  return capture ? result.stdout : "";
}

async function sealTree(path) {
  const info = await lstat(path);
  if (info.isSymbolicLink()) throw new Error(`cannot seal candidate symlink: ${path}`);
  if (info.isDirectory()) {
    for (const name of await readdir(path)) await sealTree(join(path, name));
    await chmod(path, 0o555);
  } else if (info.isFile()) await chmod(path, 0o444);
  else throw new Error(`cannot seal candidate special entry: ${path}`);
}
async function makeWritable(path) {
  const info = await lstat(path);
  if (info.isDirectory()) {
    await chmod(path, 0o755);
    for (const name of await readdir(path)) await makeWritable(join(path, name));
  } else if (info.isFile()) await chmod(path, 0o644);
}
