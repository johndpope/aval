export function displayQualificationPolicy(policy) {
  const qualification = policy?.displayCaptureQualification;
  if (qualification === null || typeof qualification !== "object" || Array.isArray(qualification)) throw new Error("display capture qualification policy is required");
  const keys = ["qualifiedScanoutProviders", "extractors", "operatorRoles", "reviewerIds"];
  if (Object.keys(qualification).sort().join(",") !== [...keys].sort().join(",")) throw new Error("display capture qualification policy fields are invalid");
  const providers = exactStringRecord(qualification.qualifiedScanoutProviders, "qualified scanout providers");
  const extractors = exactStringRecord(qualification.extractors, "display capture extractors");
  const operatorRoles = exactStringSet(qualification.operatorRoles, "display capture operator roles");
  const reviewerIds = exactStringSet(qualification.reviewerIds, "display capture reviewer IDs");
  if (extractors.size === 0 || operatorRoles.size === 0 || reviewerIds.size < 2) throw new Error("display capture qualification authority is incomplete");
  return Object.freeze({
    allowedQualifiedScanoutProviders: providers,
    allowedDisplayCaptureExtractors: extractors,
    allowedDisplayCaptureOperatorRoles: operatorRoles,
    allowedDisplayCaptureReviewerIds: reviewerIds
  });
}

function exactStringRecord(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const entries = Object.entries(value);
  for (const [key, item] of entries) if (!identifier(key) || !identifier(item)) throw new Error(`${label} contains an invalid identity`);
  return new Map(entries);
}

function exactStringSet(value, label) {
  if (!Array.isArray(value) || value.some((item) => !identifier(item)) || new Set(value).size !== value.length) throw new Error(`${label} must contain unique identities`);
  return new Set(value);
}

function identifier(value) {
  return typeof value === "string" && /^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$/u.test(value);
}
