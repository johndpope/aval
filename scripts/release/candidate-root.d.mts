import type { CandidateArtifact } from "../../packages/certification/src/model.js";
export function validateApprovedLegalReview(review: unknown): Readonly<Record<string, unknown>>;
export function validateCandidateLayout(layout: unknown, artifacts: readonly CandidateArtifact[]): Readonly<Record<string, unknown>>;
