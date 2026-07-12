import { createHash } from "node:crypto";
import { lstat, readdir, realpath } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { mediaType, readVerifiedRegularFile } from "./candidate-artifacts.mjs";

export async function collectSelfContainedReportSet({ index, indexBytes, indexPath, referenceRoot, releaseRoot } = {}) {
  const canonicalReleaseRoot = await realpath(resolve(releaseRoot));
  const canonicalReferenceRoot = await realpath(resolve(referenceRoot));
  requireWithin(canonicalReleaseRoot, canonicalReferenceRoot, "report reference root");
  const canonicalIndexPath = await realpath(resolve(indexPath));
  requireWithin(canonicalReferenceRoot, canonicalIndexPath, "report index");
  const reachable = new Set([canonicalIndexPath]);
  const reports = [];
  for (const reference of index.reports) {
    const absolute = resolveReference(canonicalReferenceRoot, reference.path, "report");
    reachable.add(absolute);
    const bytes = await readAndMatchReference(absolute, canonicalReleaseRoot, reference);
    const report = parseJson(bytes, `report ${reference.id}`);
    if (!Array.isArray(report.attachments)) throw new Error(`report ${reference.id} attachments are invalid`);
    for (const attachment of report.attachments) {
      const attachmentPath = resolveReference(dirname(absolute), attachment.path, `report attachment ${attachment.id}`);
      requireWithin(canonicalReferenceRoot, attachmentPath, `report attachment ${attachment.id}`);
      reachable.add(attachmentPath);
      await readAndMatchReference(attachmentPath, canonicalReleaseRoot, attachment);
    }
    reports.push(Object.freeze({ ...reference, path: releasePath(canonicalReleaseRoot, absolute) }));
  }

  const artifacts = [referenceFromBytes("certification-report-index", canonicalReleaseRoot, canonicalIndexPath, indexBytes)];
  if (index.reviewRecord !== null) {
    const reviewPath = resolveReference(canonicalReferenceRoot, index.reviewRecord.path, "review record");
    reachable.add(reviewPath);
    const bytes = await readAndMatchReference(reviewPath, canonicalReleaseRoot, index.reviewRecord);
    artifacts.push(Object.freeze({ ...index.reviewRecord, path: releasePath(canonicalReleaseRoot, reviewPath) }));
    if (bytes.byteLength === 0) throw new Error("review record is empty");
  }

  const actual = await collectFiles(canonicalReferenceRoot);
  for (const path of actual) {
    if (reachable.has(path)) continue;
    if (!isGeneratedSummary(path, canonicalReferenceRoot, reachable)) throw new Error(`unreferenced file in final report set: ${releasePath(canonicalReferenceRoot, path)}`);
    const bytes = await readVerifiedRegularFile(releasePath(canonicalReleaseRoot, path), canonicalReleaseRoot);
    const summaryId = createHash("sha256").update(releasePath(canonicalReferenceRoot, path)).digest("hex").slice(0, 24);
    artifacts.push(referenceFromBytes(`report-summary-${summaryId}`, canonicalReleaseRoot, path, bytes));
    reachable.add(path);
  }
  if (artifacts.length > 256) throw new Error("release report artifact count exceeds policy");
  return Object.freeze({ reports: Object.freeze(reports), artifacts: Object.freeze(artifacts), reachable: Object.freeze(reachable) });
}

function isGeneratedSummary(path, root, reachable) {
  const relativePath = releasePath(root, path);
  if (relativePath === "index.md") return true;
  if (!relativePath.endsWith(".md")) return false;
  const json = resolve(root, `${relativePath.slice(0, -3)}.json`);
  return reachable.has(json) && /(?:runtime-scheduling|observed-display)\.md$/u.test(relativePath);
}

async function collectFiles(root, directory = root, output = []) {
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`report-set symlink is forbidden: ${releasePath(root, path)}`);
    if (entry.isDirectory()) await collectFiles(root, path, output);
    else if (entry.isFile()) output.push(await realpath(path));
    else throw new Error(`report-set special entry is forbidden: ${releasePath(root, path)}`);
  }
  return output.sort();
}

async function readAndMatchReference(absolute, releaseRoot, reference) {
  const bytes = await readVerifiedRegularFile(releasePath(releaseRoot, absolute), releaseRoot, reference.byteLength);
  if (bytes.byteLength !== reference.byteLength || sha256(bytes) !== reference.sha256) throw new Error(`report reference bytes mismatch: ${reference.id}`);
  return bytes;
}

function referenceFromBytes(id, root, path, bytes) {
  return Object.freeze({ id, path: releasePath(root, path), sha256: sha256(bytes), byteLength: bytes.byteLength, mediaType: mediaType(path) });
}

function resolveReference(root, path, label) {
  if (typeof path !== "string" || path.length < 1 || path.length > 1024 || isAbsolute(path) || path.includes("\\") || path.split("/").some((part) => part === "" || part === "." || part === "..")) throw new Error(`${label} path is unsafe`);
  const absolute = resolve(root, path);
  requireWithin(root, absolute, label);
  return absolute;
}

function requireWithin(root, path, label) {
  const within = relative(root, path);
  if (within === ".." || within.startsWith(`..${sep}`) || isAbsolute(within)) throw new Error(`${label} escapes the self-contained release root`);
}

function releasePath(root, path) {
  const value = relative(root, path).split(sep).join("/");
  if (value === "" || value.startsWith("../")) throw new Error("release path is outside root");
  return value;
}

function parseJson(bytes, label) {
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch (error) { throw new Error(`${label} is not strict UTF-8 JSON`, { cause: error }); }
}
function sha256(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
