export const CERTIFICATION_STATUSES = Object.freeze([
  "passed",
  "failed",
  "unsupported",
  "inconclusive",
  "not-run",
  "withdrawn"
] as const);

export type CertificationStatus = (typeof CERTIFICATION_STATUSES)[number];

const STATUS_SET: ReadonlySet<string> = new Set(CERTIFICATION_STATUSES);

export function isCertificationStatus(value: unknown): value is CertificationStatus {
  return typeof value === "string" && STATUS_SET.has(value);
}

export function assertCertificationStatus(
  value: unknown,
  path = "status"
): asserts value is CertificationStatus {
  if (!isCertificationStatus(value)) {
    throw new CertificationValidationError(path, "unknown certification status");
  }
}

export class CertificationValidationError extends Error {
  public readonly code = "CERTIFICATION_INVALID" as const;
  public readonly path: string;

  public constructor(path: string, message: string) {
    super(`${path}: ${message}`);
    this.name = "CertificationValidationError";
    this.path = path;
  }
}
