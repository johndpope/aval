#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import { basename, dirname, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";

import { reconstructReportIndex } from "../certification/report-index-reconstruction.mjs";
import { readVerifiedRegularFile } from "./candidate-artifacts.mjs";
import { verifyCandidateRoot } from "./candidate-root.mjs";
import { collectSelfContainedReportSet } from "./release-report-set.mjs";

const args = parse(process.argv.slice(2));
const candidatePath = resolve(required(args, "candidate"));
const expectedCandidateDigest = required(args, "expected-candidate-digest");
const certification = await import(resolve("packages/certification/dist/index.js"));
const repositoryPolicy = JSON.parse(await readFile("config/release/release-policy.json", "utf8"));
const verifiedCandidate = await verifyCandidateRoot({
  manifestPath: candidatePath,
  expectedDigest: expectedCandidateDigest,
  certification,
  maximumManifestBytes: repositoryPolicy.limits.maximumReportBytes,
  maximumArtifactBytes: repositoryPolicy.limits.maximumAttachmentBytes
});
if (args["verify-environment"] === "true") {
  verifyGitIdentity(verifiedCandidate.candidate);
  await verifyBrowserPin(verifiedCandidate.candidate.browserPin, verifiedCandidate.policy);
}

let releaseDigest = null;
if (args.release !== undefined) {
  const releasePath = resolve(args.release);
  if (basename(releasePath) !== "release-manifest.json") throw new Error("release manifest filename must be release-manifest.json");
  const expectedReleaseDigest = required(args, "expected-release-digest");
  const releaseRoot = dirname(releasePath);
  if (relative(releaseRoot, candidatePath).split(sep).join("/") !== "candidate/candidate-manifest.json") throw new Error("release candidate must be rooted at candidate/candidate-manifest.json");
  const releaseBytes = await readVerifiedRegularFile("release-manifest.json", releaseRoot, verifiedCandidate.policy.limits.maximumReportBytes);
  releaseDigest = sha256(releaseBytes);
  if (releaseDigest !== expectedReleaseDigest) throw new Error("release manifest digest does not match the required digest");
  const release = certification.validateReleaseManifest(parseJson(releaseBytes, "release manifest"), verifiedCandidate.digest);
  if (Buffer.compare(releaseBytes, certification.canonicalJsonBytes(release)) !== 0) throw new Error("release manifest is not canonical JSON");
  if (release.releaseSetDigest !== verifiedCandidate.releaseSet.releaseSetDigest) throw new Error("release manifest release-set digest does not match candidate package bytes");
  if (release.previousKnownGood !== verifiedCandidate.policy.rollback.previousKnownGood || release.rollbackTag !== verifiedCandidate.policy.rollback.releaseDistTag) throw new Error("release rollback policy does not match the candidate");
  const indexReference = release.artifacts.find(({ id }) => id === "certification-report-index");
  if (indexReference === undefined || indexReference.path !== "reports/index.json") throw new Error("release is missing the self-contained report index");
  const reportIndexPath = resolve(releaseRoot, indexReference.path);
  const referenceRoot = dirname(reportIndexPath);
  const reconstruction = await reconstructReportIndex({
    indexPath: reportIndexPath,
    candidatePath,
    certification,
    policy: verifiedCandidate.policy,
    referenceRoot
  });
  if (sha256(reconstruction.indexBytes) !== indexReference.sha256 || reconstruction.indexBytes.byteLength !== indexReference.byteLength) throw new Error("release report-index reference does not match its bytes");
  if (reconstruction.index.releaseStatus !== "passed" || reconstruction.index.runtimeScheduling !== "passed") throw new Error("release report index no longer passes");
  if (reconstruction.latestEvidenceAt === null || Date.parse(release.createdAt) < Date.parse(reconstruction.latestEvidenceAt)) throw new Error("release timestamp precedes candidate, report, or review evidence");
  const reportSet = await collectSelfContainedReportSet({
    index: reconstruction.index,
    indexBytes: reconstruction.indexBytes,
    indexPath: reportIndexPath,
    referenceRoot,
    releaseRoot
  });
  const candidateReference = {
    id: "candidate-manifest",
    path: "candidate/candidate-manifest.json",
    sha256: verifiedCandidate.digest,
    byteLength: verifiedCandidate.bytes.byteLength,
    mediaType: "application/json"
  };
  requireSame(release.reports, reportSet.reports, certification, "release report references");
  requireSame(release.artifacts, [...reportSet.artifacts, candidateReference], certification, "release artifact references");
  requireSame(release.reviews, certification.assertApprovedReviews(reconstruction.index.reviews), certification, "release review decisions");
  await assertClosedReleaseRoot(releaseRoot);
}

process.stdout.write(`${JSON.stringify({ status: "passed", candidateManifestDigest: verifiedCandidate.digest, releaseSetDigest: verifiedCandidate.releaseSet.releaseSetDigest, releaseManifestDigest: releaseDigest })}\n`);

async function assertClosedReleaseRoot(root) {
  const entries = (await readdir(root, { withFileTypes: true })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  const actual = entries.map(({ name }) => name);
  if (JSON.stringify(actual) !== JSON.stringify(["candidate", "release-manifest.json", "reports"])) throw new Error(`self-contained release root has unexpected entries: ${actual.join(", ")}`);
  if (!entries.find(({ name }) => name === "candidate")?.isDirectory() || !entries.find(({ name }) => name === "reports")?.isDirectory() || !entries.find(({ name }) => name === "release-manifest.json")?.isFile()) throw new Error("self-contained release root layout is invalid");
}

function verifyGitIdentity(candidate) {
  if (git("cat-file", "-t", candidate.commit) !== "commit") throw new Error("candidate commit object is not a commit");
  if (git("cat-file", "-t", candidate.tree) !== "tree") throw new Error("candidate tree object is not a tree");
  if (candidate.tree !== git("rev-parse", `${candidate.commit}^{tree}`)) throw new Error("candidate commit/tree identity is invalid");
}

async function verifyBrowserPin(pin, policy) {
  if (pin.playwrightBrowserManifestSha256 !== policy.ci.playwrightBrowserManifestSha256) throw new Error("candidate Playwright browser manifest digest does not match policy");
  const bytes = await readFile(resolve("node_modules/playwright-core/browsers.json"));
  if (sha256(bytes) !== pin.playwrightBrowserManifestSha256) throw new Error("installed Playwright browser manifest differs from candidate pin");
  const installed = parseJson(bytes, "installed Playwright browser manifest");
  for (const name of ["chromium", "firefox", "webkit"]) {
    const expected = policy.ci.playwrightBrowsers[name];
    const actual = pin.browsers[name];
    const entry = installed.browsers.find((browser) => browser.name === name);
    if (actual.revision !== expected.revision || actual.engineVersion !== expected.engineVersion || entry?.revision !== actual.revision || entry?.browserVersion !== actual.engineVersion) throw new Error(`candidate ${name} browser pin does not match policy and installed metadata`);
  }
}

function requireSame(left, right, certification, label) {
  if (Buffer.compare(certification.canonicalJsonBytes(left), certification.canonicalJsonBytes(right)) !== 0) throw new Error(`${label} do not reconstruct from final bytes`);
}
function parseJson(bytes, label) { try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); } catch (error) { throw new Error(`${label} is not strict UTF-8 JSON`, { cause: error }); } }
function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function git(...values) { const result = spawnSync("git", values, { encoding: "utf8" }); if (result.status !== 0) throw new Error(result.stderr || "git command failed"); return result.stdout.trim(); }
function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) { const key = values[index]; if (!key?.startsWith("--")) throw new Error(`invalid argument ${String(key)}`); result[key.slice(2)] = values[index + 1] ?? "true"; } return result; }
function required(values, key) { const value = values[key]; if (typeof value !== "string" || value.length < 1) throw new Error(`--${key} is required`); return value; }
