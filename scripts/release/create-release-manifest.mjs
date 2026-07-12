#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";

import { reconstructReportIndex } from "../certification/report-index-reconstruction.mjs";
import { readVerifiedRegularFile } from "./candidate-artifacts.mjs";
import { verifyCandidateRoot } from "./candidate-root.mjs";
import { collectSelfContainedReportSet } from "./release-report-set.mjs";

const args = parse(process.argv.slice(2));
const candidatePath = resolve(required(args, "candidate"));
const expectedCandidateDigest = required(args, "expected-candidate-digest");
const reportIndexPath = resolve(required(args, "reports"));
const expectedReportIndexDigest = required(args, "expected-report-index-digest");
const referenceRoot = resolve(required(args, "reference-root"));
const output = resolve(required(args, "output"));
const releaseRoot = resolve(args.root ?? dirname(output));
const createdAt = required(args, "created-at");
requireCanonicalTimestamp(createdAt, "release created-at");
const certification = await import(resolve("packages/certification/dist/index.js"));
const repositoryPolicy = JSON.parse(await readFile("config/release/release-policy.json", "utf8"));
const verifiedCandidate = await verifyCandidateRoot({
  manifestPath: candidatePath,
  expectedDigest: expectedCandidateDigest,
  certification,
  maximumManifestBytes: repositoryPolicy.limits.maximumReportBytes,
  maximumArtifactBytes: repositoryPolicy.limits.maximumAttachmentBytes
});
const reconstruction = await reconstructReportIndex({
  indexPath: reportIndexPath,
  candidatePath,
  certification,
  policy: verifiedCandidate.policy,
  referenceRoot
});
if (createHash("sha256").update(reconstruction.indexBytes).digest("hex") !== expectedReportIndexDigest) throw new Error("report index digest does not match the approved input");
if (reconstruction.index.releaseStatus !== "passed" || reconstruction.index.runtimeScheduling !== "passed") throw new Error("report index has not passed its release gate");
certification.assertApprovedReviews(reconstruction.index.reviews);
if (reconstruction.latestEvidenceAt === null || Date.parse(createdAt) < Date.parse(reconstruction.latestEvidenceAt)) throw new Error("release created-at precedes candidate, report, or review evidence");
const reportSet = await collectSelfContainedReportSet({
  index: reconstruction.index,
  indexBytes: reconstruction.indexBytes,
  indexPath: reportIndexPath,
  referenceRoot,
  releaseRoot
});
const candidateManifestBytes = await readVerifiedRegularFile(relative(releaseRoot, candidatePath), releaseRoot, repositoryPolicy.limits.maximumReportBytes);
const manifest = {
  schemaVersion: "1.0",
  manifestKind: "release",
  releaseVersion: "1.0.0",
  candidateManifestDigest: verifiedCandidate.digest,
  releaseSetDigest: verifiedCandidate.releaseSet.releaseSetDigest,
  createdAt,
  reports: reportSet.reports,
  artifacts: [
    ...reportSet.artifacts,
    {
      id: "candidate-manifest",
      path: relative(releaseRoot, candidatePath).split("\\").join("/"),
      sha256: verifiedCandidate.digest,
      byteLength: candidateManifestBytes.byteLength,
      mediaType: "application/json"
    }
  ],
  reviews: certification.assertApprovedReviews(reconstruction.index.reviews),
  previousKnownGood: verifiedCandidate.policy.rollback.previousKnownGood,
  rollbackTag: verifiedCandidate.policy.rollback.releaseDistTag
};
certification.validateReleaseManifest(manifest, verifiedCandidate.digest);
const bytes = certification.canonicalJsonBytes(manifest);
const digest = createHash("sha256").update(bytes).digest("hex");
if (args["expected-digest"] !== undefined && args["expected-digest"] !== digest) throw new Error("release manifest digest does not match --expected-digest");
await writeFile(output, bytes, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ status: "passed", output, sha256: digest, candidateManifestDigest: verifiedCandidate.digest, releaseSetDigest: verifiedCandidate.releaseSet.releaseSetDigest })}\n`);

function parse(values) { const result = {}; for (let index = 0; index < values.length; index += 2) result[String(values[index]).replace(/^--/u, "")] = values[index + 1]; return result; }
function required(values, key) { const value = values[key]; if (typeof value !== "string" || value.length < 1) throw new Error(`--${key} is required`); return value; }
function requireCanonicalTimestamp(value, label) { const milliseconds = Date.parse(value); if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value) || !Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) throw new Error(`${label} is not a canonical real UTC timestamp`); }
