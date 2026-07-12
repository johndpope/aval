import { createHash } from "node:crypto";
import { canonicalJsonBytes } from "./canonical-json.js";
import { SHA256_PATTERN } from "./model.js";

export interface CertificationReviewEntry {
  readonly id: string;
  readonly decision: "approved" | "rejected";
  readonly reviewedAt: string;
  readonly reviewedReportIds: readonly string[];
}

export interface CertificationReviewSummary {
  readonly id: string;
  readonly decision: "approved" | "rejected";
  readonly evidenceDigest: string;
}

export function validateReviewRecord(
  input: unknown,
  expectedCandidateDigest: string,
  requiredRuntimeReportIds: readonly string[],
  reportEndedAt: ReadonlyMap<string, string> = new Map()
): Readonly<{ readonly reviews: readonly CertificationReviewEntry[]; readonly summaries: readonly CertificationReviewSummary[] }> {
  if (!SHA256_PATTERN.test(expectedCandidateDigest)) throw new TypeError("expected candidate digest is invalid");
  const requiredIds = validateIdSet(requiredRuntimeReportIds, "required runtime report IDs", 256);
  const root = exactRecord(input, ["schemaVersion", "candidateManifestDigest", "reviews"], "$reviews");
  if (root.schemaVersion !== "1.0" || root.candidateManifestDigest !== expectedCandidateDigest) throw new TypeError("review record candidate identity is invalid");
  if (!Array.isArray(root.reviews) || root.reviews.length > 32) throw new RangeError("review record must contain at most 32 reviews");
  const reviewerIds = new Set<string>();
  const reviews = root.reviews.map((value, index): CertificationReviewEntry => {
    const path = `$reviews.reviews[${String(index)}]`;
    const review = exactRecord(value, ["id", "decision", "reviewedAt", "reviewedReportIds"], path);
    const id = identifier(review.id, `${path}.id`);
    if (reviewerIds.has(id)) throw new TypeError(`duplicate reviewer ID: ${id}`);
    reviewerIds.add(id);
    if (review.decision !== "approved" && review.decision !== "rejected") throw new TypeError(`${path}.decision is invalid`);
    const reviewedAt = timestamp(review.reviewedAt, `${path}.reviewedAt`);
    if (!Array.isArray(review.reviewedReportIds)) throw new TypeError(`${path}.reviewedReportIds must be an array`);
    const reviewedReportIds = validateIdSet(review.reviewedReportIds, `${path}.reviewedReportIds`, 256);
    if (reviewedReportIds.length !== requiredIds.length || reviewedReportIds.some((value, itemIndex) => value !== requiredIds[itemIndex])) {
      throw new TypeError(`${path} does not cover the exact sorted runtime report set`);
    }
    for (const reportId of reviewedReportIds) {
      const endedAt = reportEndedAt.get(reportId);
      if (endedAt !== undefined && Date.parse(reviewedAt) < Date.parse(timestamp(endedAt, `report ${reportId} endedAt`))) throw new TypeError(`${path}.reviewedAt precedes report ${reportId}`);
    }
    return Object.freeze({ id, decision: review.decision, reviewedAt, reviewedReportIds: Object.freeze(reviewedReportIds) });
  });
  const summaries = reviews.map((review) => Object.freeze({
    id: review.id,
    decision: review.decision,
    evidenceDigest: createHash("sha256").update(canonicalJsonBytes(review)).digest("hex")
  }));
  return Object.freeze({ reviews: Object.freeze(reviews), summaries: Object.freeze(summaries) });
}

export function assertApprovedReviews(
  summaries: readonly CertificationReviewSummary[],
  minimum = 2
): readonly Readonly<{ readonly id: string; readonly decision: "approved"; readonly evidenceDigest: string }>[] {
  if (!Number.isSafeInteger(minimum) || minimum < 2 || minimum > 32) throw new RangeError("review minimum is invalid");
  if (summaries.length < minimum) throw new Error(`at least ${String(minimum)} independent reviews are required`);
  const ids = new Set<string>();
  return Object.freeze(summaries.map((summary) => {
    const id = identifier(summary.id, "review summary ID");
    if (ids.has(id)) throw new TypeError(`duplicate reviewer ID: ${id}`);
    ids.add(id);
    if (summary.decision !== "approved") throw new Error(`review ${id} is not approved`);
    if (!SHA256_PATTERN.test(summary.evidenceDigest)) throw new TypeError(`review ${id} evidence digest is invalid`);
    return Object.freeze({ id, decision: "approved" as const, evidenceDigest: summary.evidenceDigest });
  }));
}

function validateIdSet(values: readonly unknown[], path: string, maximum: number): string[] {
  if (values.length > maximum) throw new RangeError(`${path} exceeds ${String(maximum)} items`);
  const checked = values.map((value, index) => identifier(value, `${path}[${String(index)}]`));
  if (new Set(checked).size !== checked.length) throw new TypeError(`${path} contains duplicates`);
  const sorted = [...checked].sort(compareAscii);
  if (checked.some((value, index) => value !== sorted[index])) throw new TypeError(`${path} must use canonical ASCII order`);
  return checked;
}

function exactRecord(value: unknown, keys: readonly string[], path: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${path} must be an object`);
  const record = value as Record<string, unknown>;
  const allowed = new Set(keys);
  for (const key of Object.keys(record)) if (!allowed.has(key)) throw new TypeError(`${path}.${key} is an unknown field`);
  for (const key of keys) if (!(key in record)) throw new TypeError(`${path}.${key} is required`);
  return record;
}

function identifier(value: unknown, path: string): string {
  if (typeof value !== "string" || !/^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$/u.test(value)) throw new TypeError(`${path} is invalid`);
  return value;
}

function timestamp(value: unknown, path: string): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value)) throw new TypeError(`${path} is invalid`);
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) throw new TypeError(`${path} is not a canonical real UTC timestamp`);
  return value;
}

function compareAscii(left: string, right: string): number { return left < right ? -1 : left > right ? 1 : 0; }
