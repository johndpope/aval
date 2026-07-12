export interface CandidateToolchainPolicy {
  readonly minimumNode: string;
  readonly minimumNpm: string;
  readonly candidateNode: string;
  readonly candidateNpm: string;
  readonly typescript: string;
  readonly vitest: string;
  readonly playwright: string;
  readonly apiExtractor: string;
}

export interface CandidateToolchainCapture {
  readonly node: string;
  readonly npm: string;
  readonly typescript: string;
  readonly vitest: string;
  readonly playwright: string;
  readonly apiExtractor: string;
}

export function validateCandidateToolchain(
  policy: Readonly<CandidateToolchainPolicy>,
  actual: Readonly<CandidateToolchainCapture>
): CandidateToolchainCapture {
  const policyNames = ["minimumNode", "minimumNpm", "candidateNode", "candidateNpm", "typescript", "vitest", "playwright", "apiExtractor"] as const;
  const captureNames = ["node", "npm", "typescript", "vitest", "playwright", "apiExtractor"] as const;
  assertExactKeys(policy as unknown as Record<string, unknown>, policyNames, "toolchain policy");
  assertExactKeys(actual as unknown as Record<string, unknown>, captureNames, "toolchain capture");
  for (const name of policyNames) parseVersion(policy[name], name);
  for (const name of captureNames) parseVersion(actual[name], name);
  if (compareVersions(actual.node, policy.minimumNode) < 0) throw new Error(`node ${actual.node} is below package engine minimum ${policy.minimumNode}`);
  if (compareVersions(actual.npm, policy.minimumNpm) < 0) throw new Error(`npm ${actual.npm} is below candidate minimum ${policy.minimumNpm}`);
  const expected: CandidateToolchainCapture = {
    node: policy.candidateNode,
    npm: policy.candidateNpm,
    typescript: policy.typescript,
    vitest: policy.vitest,
    playwright: policy.playwright,
    apiExtractor: policy.apiExtractor
  };
  for (const [name, version] of Object.entries(expected)) {
    if (actual[name as keyof CandidateToolchainCapture] !== version) {
      throw new Error(`${name} ${actual[name as keyof CandidateToolchainCapture]} does not match candidate pin ${version}`);
    }
  }
  return Object.freeze({ ...actual });
}

function assertExactKeys(value: Record<string, unknown>, expected: readonly string[], name: string): void {
  const keys = Object.keys(value);
  const allowed = new Set(expected);
  const unknown = keys.find((key) => !allowed.has(key));
  if (unknown !== undefined) throw new TypeError(`${name} has unknown field ${unknown}`);
  const missing = expected.find((key) => !(key in value));
  if (missing !== undefined) throw new TypeError(`${name} is missing ${missing}`);
}

export function compareVersions(left: string, right: string): number {
  const a = parseVersion(left, "left version");
  const b = parseVersion(right, "right version");
  for (let index = 0; index < 3; index += 1) {
    const delta = a[index]! - b[index]!;
    if (delta !== 0) return delta < 0 ? -1 : 1;
  }
  return 0;
}

function parseVersion(value: unknown, name: string): readonly [number, number, number] {
  if (typeof value !== "string") throw new TypeError(`${name} must be a semantic version`);
  const match = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u.exec(value);
  if (match === null) throw new TypeError(`${name} must be an exact major.minor.patch version`);
  const parts = [Number(match[1]), Number(match[2]), Number(match[3])] as const;
  if (parts.some((part) => !Number.isSafeInteger(part))) throw new RangeError(`${name} exceeds safe version bounds`);
  return parts;
}
