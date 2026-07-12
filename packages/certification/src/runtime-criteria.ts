import type { CertificationStatus } from "./status.js";

export interface RuntimeFrameLedgerEntry {
  readonly deadlineOrdinal: number;
  readonly requiredContentOrdinal: number;
  readonly submittedContentOrdinal: number | null;
  readonly boundary: boolean;
  readonly eligible: boolean;
  readonly formatUnderflow: boolean;
  readonly canvasSubmissionGapMicroseconds: number;
}

export interface RuntimeCounterSnapshot {
  readonly configure: number;
  readonly reset: number;
  readonly flush: number;
  readonly reconfigure: number;
  readonly seek: number;
  readonly stalePublications: number;
  readonly capViolations: number;
  readonly untrackedOwnedBytes: number;
  readonly terminalOwnedResources: number;
}

export interface RuntimeCounterWindow {
  /** Snapshot after preparation and warm-up; initial decoder configuration is outside the measured window. */
  readonly baseline: RuntimeCounterSnapshot;
  /** Snapshot immediately after the measured continuity window and terminal settlement. */
  readonly terminal: RuntimeCounterSnapshot;
  /** Normative per-field measured-window allowances. Omitted fields allow no increase. */
  readonly allowedDeltas?: Readonly<Partial<RuntimeCounterSnapshot>>;
}

export interface RuntimeCriteriaInput {
  readonly frames: readonly RuntimeFrameLedgerEntry[];
  readonly idealContentFrameIntervalMicroseconds: number;
  readonly throughput: {
    readonly outputFrames: number;
    readonly elapsedMicroseconds: number;
    readonly authoredFramesPerSecondMillionths: number;
  };
  readonly counterWindow: RuntimeCounterWindow;
}

export interface RuntimeCriteriaResult {
  readonly status: CertificationStatus;
  readonly thresholdMicroseconds: number;
  readonly nonBoundaryP99Microseconds: number;
  readonly firstFailingDeadlineOrdinal: number | null;
  readonly throughputRatioMillionths: number;
  readonly counterDeltas: RuntimeCounterSnapshot;
  readonly failures: readonly string[];
}

const COUNTER_NAMES = Object.freeze([
  "configure", "reset", "flush", "reconfigure", "seek", "stalePublications",
  "capViolations", "untrackedOwnedBytes", "terminalOwnedResources"
] as const satisfies readonly (keyof RuntimeCounterSnapshot)[]);

export function evaluateRuntimeCriteria(input: RuntimeCriteriaInput): RuntimeCriteriaResult {
  const failures: string[] = [];
  positiveFinite(input.idealContentFrameIntervalMicroseconds, "idealContentFrameIntervalMicroseconds");
  if (input.frames.length === 0) failures.push("frame-ledger-empty");
  const nonBoundary = input.frames
    .filter((entry) => entry.eligible && !entry.boundary)
    .map((entry) => checkedNonnegative(entry.canvasSubmissionGapMicroseconds, "canvasSubmissionGapMicroseconds"));
  const nonBoundaryP99Microseconds = quantileNearestRank(nonBoundary, 99, 100);
  const thresholdMicroseconds = Math.max(
    input.idealContentFrameIntervalMicroseconds * 1.5,
    nonBoundaryP99Microseconds + input.idealContentFrameIntervalMicroseconds * 0.5
  );
  let firstFailingDeadlineOrdinal: number | null = null;
  let eligibleFrames = 0;
  let priorDeadline = -1;
  for (const frame of input.frames) {
    checkedNonnegativeInteger(frame.deadlineOrdinal, "deadlineOrdinal");
    checkedNonnegativeInteger(frame.requiredContentOrdinal, "requiredContentOrdinal");
    if (frame.deadlineOrdinal <= priorDeadline) failures.push("deadline-ordinals-not-strictly-increasing");
    priorDeadline = frame.deadlineOrdinal;
    if (!frame.eligible) continue;
    eligibleFrames += 1;
    const failed = frame.formatUnderflow || frame.submittedContentOrdinal !== frame.requiredContentOrdinal ||
      (frame.boundary && frame.canvasSubmissionGapMicroseconds > thresholdMicroseconds);
    if (failed && firstFailingDeadlineOrdinal === null) firstFailingDeadlineOrdinal = frame.deadlineOrdinal;
    if (frame.formatUnderflow) failures.push(`format-underflow:${frame.deadlineOrdinal}`);
    if (frame.submittedContentOrdinal !== frame.requiredContentOrdinal) failures.push(`content-identity:${frame.deadlineOrdinal}`);
    if (frame.boundary && frame.canvasSubmissionGapMicroseconds > thresholdMicroseconds) failures.push(`boundary-gap:${frame.deadlineOrdinal}`);
  }
  if (eligibleFrames === 0) failures.push("eligible-frame-ledger-empty");
  const throughputFrames = checkedNonnegativeInteger(input.throughput.outputFrames, "throughput.outputFrames");
  const elapsed = positiveFinite(input.throughput.elapsedMicroseconds, "throughput.elapsedMicroseconds");
  const authoredFpsMillionths = checkedPositiveInteger(input.throughput.authoredFramesPerSecondMillionths, "throughput.authoredFramesPerSecondMillionths");
  const actualFpsMillionths = throughputFrames * 1_000_000_000_000 / elapsed;
  const throughputRatioMillionths = Math.floor(actualFpsMillionths * 1_000_000 / authoredFpsMillionths);
  if (throughputFrames < 300) failures.push("throughput-sample-count-below-300");
  if (throughputRatioMillionths < 1_500_000) failures.push("throughput-below-1.5x");
  const counterDeltas = evaluateCounterWindow(input.counterWindow, failures);
  return {
    status: failures.length === 0 ? "passed" : "failed",
    thresholdMicroseconds,
    nonBoundaryP99Microseconds,
    firstFailingDeadlineOrdinal,
    throughputRatioMillionths,
    counterDeltas,
    failures
  };
}

function evaluateCounterWindow(
  window: RuntimeCounterWindow,
  failures: string[]
): RuntimeCounterSnapshot {
  if (window === null || typeof window !== "object") throw new TypeError("counterWindow must be an object");
  const allowed = window.allowedDeltas ?? {};
  const unknownAllowed = Object.keys(allowed).filter((name) => !COUNTER_NAMES.includes(name as keyof RuntimeCounterSnapshot));
  if (unknownAllowed.length > 0) throw new TypeError(`unknown counter allowance: ${unknownAllowed[0]}`);
  const deltas = Object.create(null) as Record<keyof RuntimeCounterSnapshot, number>;
  for (const name of COUNTER_NAMES) {
    const baseline = checkedNonnegativeInteger(window.baseline[name], `counterWindow.baseline.${name}`);
    const terminal = checkedNonnegativeInteger(window.terminal[name], `counterWindow.terminal.${name}`);
    if (terminal < baseline) throw new RangeError(`counterWindow.terminal.${name} must not precede the measured-window baseline`);
    const delta = terminal - baseline;
    deltas[name] = delta;
    const allowance = checkedNonnegativeInteger(allowed[name] ?? 0, `counterWindow.allowedDeltas.${name}`);
    if (delta > allowance) failures.push(`counter-delta:${name}:${delta}>${allowance}`);
  }
  for (const name of ["untrackedOwnedBytes", "terminalOwnedResources"] as const) {
    if (window.baseline[name] !== 0) failures.push(`counter-baseline-nonzero:${name}`);
    if (window.terminal[name] !== 0) failures.push(`counter-terminal-nonzero:${name}`);
  }
  return Object.freeze(deltas) as unknown as RuntimeCounterSnapshot;
}

export function quantileNearestRank(values: readonly number[], numerator: number, denominator: number): number {
  if (values.length === 0) return 0;
  checkedPositiveInteger(numerator, "numerator");
  checkedPositiveInteger(denominator, "denominator");
  if (numerator > denominator) throw new RangeError("numerator must not exceed denominator");
  const sorted = [...values].map((value) => checkedNonnegative(value, "sample")).sort((left, right) => left - right);
  const rank = Math.max(1, Math.ceil(sorted.length * numerator / denominator));
  return sorted[rank - 1] ?? 0;
}

function checkedNonnegativeInteger(value: number, field: string): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`${field} must be a nonnegative safe integer`);
  return value;
}

function checkedPositiveInteger(value: number, field: string): number {
  checkedNonnegativeInteger(value, field);
  if (value === 0) throw new RangeError(`${field} must be positive`);
  return value;
}

function checkedNonnegative(value: number, field: string): number {
  if (!Number.isFinite(value) || value < 0) throw new RangeError(`${field} must be finite and nonnegative`);
  return value;
}

function positiveFinite(value: number, field: string): number {
  checkedNonnegative(value, field);
  if (value === 0) throw new RangeError(`${field} must be positive`);
  return value;
}
