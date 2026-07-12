import { createHash } from "node:crypto";
import { readdir, realpath } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

import { readVerifiedRegularFile, verifyArtifactIndex } from "./candidate-artifacts.mjs";
import { loadVerifiedReleaseSet, reconcilePackageInspection, validateReleasePolicy } from "./release-set.mjs";
import { reconcileReleaseSbomSet } from "../security/sbom-model.mjs";
import { reconcileLicenseReport } from "../security/license-model.mjs";
import { reconcilePublicationMetadata, validateApprovedPublicationMetadata } from "./publication-metadata.mjs";
import { reconcileProductionPublicEntryManifest } from "./public-entry-authority.mjs";

export async function verifyCandidateArtifactSet({ root, artifacts, maximumArtifactBytes } = {}) {
  const verified = await verifyArtifactIndex({ schemaVersion: "1.0", artifacts }, root, {
    requireCandidateRoles: true,
    maximumBytes: maximumArtifactBytes
  });
  const policy = parseJson(requiredBytes(verified.bytesByPath, "config/release/release-policy.json"), "candidate release policy");
  validateReleasePolicy(policy);
  const packageIndex = parseJson(requiredBytes(verified.bytesByPath, "package-index.json"), "candidate package index");
  const inspection = parseJson(requiredBytes(verified.bytesByPath, "package-inspection.json"), "candidate package inspection");
  const releaseSet = await loadVerifiedReleaseSet({ directory: join(resolve(root), "packages"), policy, packageIndex });
  reconcilePackageInspection(inspection, releaseSet);
  verifyPackageArtifactReferences(artifacts, releaseSet);
  const sboms = new Map(artifacts.filter(({ role }) => role === "sbom").map(({ path }) => [path, parseJson(requiredBytes(verified.bytesByPath, path), `candidate SBOM ${path}`)]));
  reconcileReleaseSbomSet({ documentsByPath: sboms, releaseSet, workspaceLockBytes: requiredBytes(verified.bytesByPath, "package-lock.json") });
  reconcileLicenseReport(
    parseJson(requiredBytes(verified.bytesByPath, "license-report.json"), "candidate license report"),
    requiredBytes(verified.bytesByPath, "package-lock.json"),
    requiredBytes(verified.bytesByPath, "config/release/license-policy.json")
  );
  const publicationMetadata = validateApprovedPublicationMetadata(parseJson(requiredBytes(verified.bytesByPath, "config/release/publication-metadata.json"), "candidate publication metadata"));
  reconcilePublicationMetadata(releaseSet.manifests, publicationMetadata);
  const publicEntryManifest = reconcileProductionPublicEntryManifest(
    parseJson(requiredBytes(verified.bytesByPath, "assets/public-entry-manifest.json"), "candidate production public-entry manifest"),
    inspection
  );
  const legalReview = validateApprovedLegalReview(parseJson(requiredBytes(verified.bytesByPath, "config/release/legal-review.json"), "candidate legal review"));
  const layout = validateCandidateLayout(parseJson(requiredBytes(verified.bytesByPath, "candidate-layout.json"), "candidate layout"), artifacts);
  return Object.freeze({ verified, policy, releaseSet, packageIndex, inspection, publicationMetadata, publicEntryManifest, legalReview, layout });
}

export async function verifyCandidateRoot({ manifestPath, expectedDigest, certification, maximumManifestBytes = 16 * 1024 * 1024, maximumArtifactBytes } = {}) {
  if (certification === undefined) throw new TypeError("certification authority is required");
  const absoluteManifest = resolve(manifestPath);
  if (basename(absoluteManifest) !== "candidate-manifest.json") throw new Error("candidate manifest filename must be candidate-manifest.json");
  const candidateRoot = dirname(absoluteManifest);
  const bytes = await readVerifiedRegularFile("candidate-manifest.json", candidateRoot, maximumManifestBytes);
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (expectedDigest !== undefined && digest !== expectedDigest) throw new Error("candidate manifest digest does not match the required digest");
  const candidate = certification.validateCandidateManifest(parseJson(bytes, "candidate manifest"));
  if (Buffer.compare(bytes, certification.canonicalJsonBytes(candidate)) !== 0) throw new Error("candidate manifest is not canonical JSON");
  const artifactSet = await verifyCandidateArtifactSet({ root: candidateRoot, artifacts: candidate.artifacts, maximumArtifactBytes });
  if (candidate.releaseSetDigest !== artifactSet.releaseSet.releaseSetDigest) throw new Error("candidate manifest release-set digest does not match exact package bytes");
  if (candidate.commit !== artifactSet.layout.commit || candidate.tree !== artifactSet.layout.tree) throw new Error("candidate manifest source identity does not match candidate layout");
  await assertNoUnmanifestedCandidateFiles(candidateRoot, candidate.artifacts);
  return Object.freeze({ root: candidateRoot, path: absoluteManifest, bytes, digest, candidate, ...artifactSet });
}

async function assertNoUnmanifestedCandidateFiles(root, artifacts) {
  const canonicalRoot = await realpath(root);
  const expected = new Set(["candidate-manifest.json", ...artifacts.map(({ path }) => path)]);
  const actual = await collectFiles(canonicalRoot);
  for (const path of actual) if (!expected.delete(path)) throw new Error(`candidate root contains an unmanifested file: ${path}`);
  if (expected.size > 0) throw new Error(`candidate root is missing a manifest-bound file: ${[...expected].sort().join(", ")}`);
}

async function collectFiles(root, directory = root, output = []) {
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`candidate root symlink is forbidden: ${relative(root, path).split(sep).join("/")}`);
    if (entry.isDirectory()) await collectFiles(root, path, output);
    else if (entry.isFile()) output.push(relative(root, await realpath(path)).split(sep).join("/"));
    else throw new Error(`candidate root special entry is forbidden: ${relative(root, path).split(sep).join("/")}`);
  }
  return output;
}

export function validateApprovedLegalReview(review) {
  if (review === null || typeof review !== "object" || Array.isArray(review)) throw new Error("candidate legal review is invalid");
  const keys = ["schemaVersion", "releaseVersion", "status", "reviewId", "reviewerRole", "reviewedAt", "scope", "note"];
  if (Object.keys(review).sort().join(",") !== keys.sort().join(",")) throw new Error("candidate legal review fields are invalid");
  if (review.schemaVersion !== "1.0" || review.releaseVersion !== "1.0.0" || review.status !== "approved") throw new Error("approved legal review is required before candidate use");
  if (typeof review.reviewId !== "string" || !/^[a-z0-9][a-z0-9._-]{7,127}$/u.test(review.reviewId)) throw new Error("candidate legal review reviewId is invalid");
  if (review.reviewerRole !== "qualified-legal-reviewer") throw new Error("candidate legal review reviewerRole is invalid");
  if (typeof review.reviewedAt !== "string" || review.reviewedAt.length > 32) throw new Error("candidate legal review reviewedAt is invalid");
  if (!isCanonicalTimestamp(review.reviewedAt)) throw new Error("candidate legal review time is invalid");
  const expectedScope = ["project-license", "dependency-licenses", "codec-and-patent-obligations", "fixture-and-source-media-rights", "package-names-and-registry-scope"];
  if (!Array.isArray(review.scope) || JSON.stringify([...review.scope].sort()) !== JSON.stringify([...expectedScope].sort())) throw new Error("candidate legal review scope is invalid");
  if (typeof review.note !== "string" || review.note.length < 1 || review.note.length > 2048) throw new Error("candidate legal review note is invalid");
  return review;
}

function isCanonicalTimestamp(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)) return false;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) && new Date(milliseconds).toISOString() === value;
}

export function validateCandidateLayout(layout, artifacts) {
  if (layout === null || typeof layout !== "object" || Array.isArray(layout)) throw new Error("candidate layout is invalid");
  const keys = ["schemaVersion", "releaseVersion", "commit", "tree", "files", "coverage"];
  if (Object.keys(layout).sort().join(",") !== keys.sort().join(",") || layout.schemaVersion !== "1.0" || layout.releaseVersion !== "1.0.0" || !/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/u.test(layout.commit) || !/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/u.test(layout.tree) || !Array.isArray(layout.files)) throw new Error("candidate layout identity is invalid");
  const expected = artifacts.filter(({ role }) => role !== "candidate-layout").sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
  if (layout.files.length !== expected.length) throw new Error("candidate layout file count does not match manifest artifacts");
  for (const [index, value] of layout.files.entries()) {
    const artifact = expected[index];
    if (value === null || typeof value !== "object" || Array.isArray(value) || Object.keys(value).sort().join(",") !== "byteLength,path,role,sha256" || artifact === undefined || value.path !== artifact.path || value.role !== artifact.role || value.sha256 !== artifact.sha256 || value.byteLength !== artifact.byteLength) throw new Error(`candidate layout file does not match manifest artifact at index ${String(index)}`);
  }
  const roles = ["schema", "fixture", "documentation", "example", "browser-harness"];
  if (layout.coverage === null || typeof layout.coverage !== "object" || Array.isArray(layout.coverage) || Object.keys(layout.coverage).sort().join(",") !== [...roles].sort().join(",")) throw new Error("candidate layout coverage fields are invalid");
  for (const role of roles) {
    const reconstructed = expected.filter((artifact) => artifact.role === role).map(({ path }) => path);
    if (reconstructed.length === 0 || JSON.stringify(layout.coverage[role]) !== JSON.stringify(reconstructed)) throw new Error(`candidate layout ${role} coverage does not reconstruct`);
  }
  return layout;
}

function verifyPackageArtifactReferences(artifacts, releaseSet) {
  const packageReferences = artifacts.filter(({ role }) => role === "package");
  if (packageReferences.length !== releaseSet.packages.length) throw new Error("candidate package artifact count does not match release set");
  const byPath = new Map(packageReferences.map((reference) => [reference.path, reference]));
  for (const entry of releaseSet.packages) {
    const reference = byPath.get(`packages/${entry.filename}`);
    if (reference === undefined || reference.sha256 !== entry.tarballSha256 || reference.byteLength !== entry.byteLength || reference.mediaType !== "application/gzip") throw new Error(`candidate package reference does not match exact archive bytes: ${entry.name}`);
  }
}

function requiredBytes(map, path) {
  const bytes = map.get(path);
  if (bytes === undefined) throw new Error(`candidate is missing ${path}`);
  return bytes;
}

function parseJson(bytes, label) {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (error) {
    throw new Error(`${label} is not strict UTF-8 JSON`, { cause: error });
  }
}
