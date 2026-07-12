import { describe, expect, it } from "vitest";
import { assertApprovedReviews, validateReviewRecord } from "../src/review-record.js";

const candidate = "a".repeat(64);
const reports = ["runtime-a", "runtime-b"];
const valid = {
  schemaVersion: "1.0",
  candidateManifestDigest: candidate,
  reviews: [
    { id: "reviewer-a", decision: "approved", reviewedAt: "2026-07-12T12:00:00.000Z", reviewedReportIds: reports },
    { id: "reviewer-b", decision: "approved", reviewedAt: "2026-07-12T12:01:00.000Z", reviewedReportIds: reports }
  ]
};

describe("canonical independent review records", () => {
  it("binds each approved decision to its complete canonical report set", () => {
    const result = validateReviewRecord(valid, candidate, reports);
    expect(result.summaries).toHaveLength(2);
    expect(result.summaries.every(({ evidenceDigest }) => /^[0-9a-f]{64}$/u.test(evidenceDigest))).toBe(true);
    expect(assertApprovedReviews(result.summaries)).toEqual(result.summaries);
  });

  it("rejects missing coverage, rejected decisions at release, and unknown fields", () => {
    expect(() => validateReviewRecord({ ...valid, reviews: [{ ...valid.reviews[0], reviewedReportIds: ["runtime-a"] }] }, candidate, reports)).toThrow(/exact sorted runtime report set/u);
    const rejected = validateReviewRecord({ ...valid, reviews: valid.reviews.map((review, index) => index === 0 ? { ...review, decision: "rejected" } : review) }, candidate, reports);
    expect(() => assertApprovedReviews(rejected.summaries)).toThrow(/not approved/u);
    expect(() => validateReviewRecord({ ...valid, extra: true }, candidate, reports)).toThrow(/unknown field/u);
    expect(() => validateReviewRecord({ ...valid, reviews: [{ ...valid.reviews[0], extra: true }] }, candidate, reports)).toThrow(/unknown field/u);
  });

  it("rejects substitution, duplicates, and non-canonical report ordering", () => {
    expect(() => validateReviewRecord(valid, "b".repeat(64), reports)).toThrow(/candidate identity/u);
    expect(() => validateReviewRecord({ ...valid, reviews: [valid.reviews[0], valid.reviews[0]] }, candidate, reports)).toThrow(/duplicate reviewer/u);
    expect(() => validateReviewRecord({ ...valid, reviews: valid.reviews.map((review) => ({ ...review, reviewedReportIds: [...reports].reverse() })) }, candidate, reports)).toThrow(/canonical ASCII/u);
    expect(() => validateReviewRecord(valid, candidate, reports, new Map([["runtime-a", "2026-07-12T12:30:00.000Z"]]))).toThrow(/precedes report/u);
    expect(() => validateReviewRecord({ ...valid, reviews: [{ ...valid.reviews[0], reviewedAt: "2026-02-30T12:00:00.000Z" }] }, candidate, reports)).toThrow(/canonical real UTC/u);
  });
});
