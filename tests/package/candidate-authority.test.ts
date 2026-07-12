import { describe, expect, it } from "vitest";

import { candidateArtifactFixture } from "../../packages/certification/test/candidate-manifest-fixture.js";
import { validateApprovedLegalReview, validateCandidateLayout } from "../../scripts/release/candidate-root.mjs";

describe("candidate layout and legal authorities", () => {
  it("reconstructs complete schema, fixture, docs, examples, and harness coverage", () => {
    const artifacts = candidateArtifactFixture();
    const files = artifacts.filter(({ role }) => role !== "candidate-layout").sort((left, right) => left.path < right.path ? -1 : 1).map(({ path, role, sha256, byteLength }) => ({ path, role, sha256, byteLength }));
    const roles = ["schema", "fixture", "documentation", "example", "browser-harness"] as const;
    const layout = {
      schemaVersion: "1.0",
      releaseVersion: "1.0.0",
      commit: "1".repeat(40),
      tree: "2".repeat(40),
      files,
      coverage: Object.fromEntries(roles.map((role) => [role, files.filter((file) => file.role === role).map(({ path }) => path)]))
    };
    expect(validateCandidateLayout(layout, artifacts)).toBe(layout);
    expect(() => validateCandidateLayout({ ...layout, files: files.filter(({ role }) => role !== "documentation") }, artifacts)).toThrow(/file count/u);
    expect(() => validateCandidateLayout({ ...layout, coverage: { ...layout.coverage, fixture: [] } }, artifacts)).toThrow(/fixture coverage/u);
  });

  it("requires the exact qualified legal scope and rejects self-asserted extra fields", () => {
    const review = {
      schemaVersion: "1.0",
      releaseVersion: "1.0.0",
      status: "approved",
      reviewId: "legal-review-2026-001",
      reviewerRole: "qualified-legal-reviewer",
      reviewedAt: "2026-07-12T13:00:00.000Z",
      scope: ["project-license", "dependency-licenses", "codec-and-patent-obligations", "fixture-and-source-media-rights", "package-names-and-registry-scope"],
      note: "Independent qualified review completed."
    };
    expect(validateApprovedLegalReview(review)).toBe(review);
    expect(() => validateApprovedLegalReview({ ...review, scope: ["project-license"] })).toThrow(/scope/u);
    expect(() => validateApprovedLegalReview({ ...review, reviewerRole: "release-author" })).toThrow(/reviewerRole/u);
    expect(() => validateApprovedLegalReview({ ...review, selfAsserted: true })).toThrow(/fields/u);
    expect(() => validateApprovedLegalReview({ ...review, status: "pending", reviewId: null, reviewerRole: null, reviewedAt: null })).toThrow(/approved legal review/u);
    expect(() => validateApprovedLegalReview({ ...review, reviewedAt: "2026-02-30T13:00:00.000Z" })).toThrow(/time/u);
  });
});
