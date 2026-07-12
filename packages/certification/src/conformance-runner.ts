import type { CertificationStatus } from "./status.js";
import { isCertificationStatus } from "./status.js";

export interface ConformanceCaseResult {
  readonly id: string;
  readonly status: CertificationStatus;
  readonly durationMilliseconds: number;
  readonly assertions: number;
  readonly summary: string;
}

export interface ConformanceTaskContext {
  readonly signal: AbortSignal;
  readonly seed: number;
}

export interface ConformanceTask {
  readonly id: string;
  readonly seed: number;
  run(context: ConformanceTaskContext): Promise<{
    readonly status: CertificationStatus;
    readonly assertions: number;
    readonly summary: string;
  }>;
}

export interface ConformanceRun {
  readonly schemaVersion: "1.0";
  readonly status: CertificationStatus;
  readonly startedAt: string;
  readonly endedAt: string;
  readonly cases: readonly ConformanceCaseResult[];
}

export async function runConformance(
  tasks: readonly ConformanceTask[],
  options: { readonly signal?: AbortSignal; readonly maximumTasks?: number; readonly now?: () => number; readonly wallClock?: () => string } = {}
): Promise<ConformanceRun> {
  const maximum = options.maximumTasks ?? 1_024;
  if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 10_000) throw new RangeError("maximumTasks must be in 1..10000");
  if (tasks.length === 0) throw new RangeError("at least one conformance task is required");
  if (tasks.length > maximum) throw new RangeError("conformance task limit exceeded");
  const ids = new Set<string>();
  for (const task of tasks) {
    if (!/^[a-z0-9][a-z0-9._-]{0,127}$/u.test(task.id)) throw new TypeError(`invalid conformance task ID: ${task.id}`);
    if (ids.has(task.id)) throw new TypeError(`duplicate conformance task ID: ${task.id}`);
    if (!Number.isSafeInteger(task.seed) || task.seed < 0 || task.seed > 0xffff_ffff) throw new RangeError(`invalid seed for ${task.id}`);
    ids.add(task.id);
  }
  const now = options.now ?? (() => performance.now());
  const wallClock = options.wallClock ?? (() => new Date().toISOString());
  const startedAt = wallClock();
  const controller = new AbortController();
  const abort = () => controller.abort(options.signal?.reason);
  options.signal?.addEventListener("abort", abort, { once: true });
  const results: ConformanceCaseResult[] = [];
  try {
    for (const task of tasks) {
      if (controller.signal.aborted) {
        results.push({ id: task.id, status: "not-run", durationMilliseconds: 0, assertions: 0, summary: "run aborted before case" });
        continue;
      }
      const start = now();
      try {
        const result = await task.run({ signal: controller.signal, seed: task.seed });
        if (!isCertificationStatus(result.status)) throw new TypeError("task returned an unknown status");
        if (!Number.isSafeInteger(result.assertions) || result.assertions < 0 || result.assertions > 10_000_000) throw new RangeError("task assertion count is invalid");
        results.push({
          id: task.id,
          status: result.status,
          durationMilliseconds: boundedDuration(now() - start),
          assertions: result.assertions,
          summary: boundedSummary(result.summary)
        });
      } catch (error) {
        results.push({
          id: task.id,
          status: controller.signal.aborted ? "inconclusive" : "failed",
          durationMilliseconds: boundedDuration(now() - start),
          assertions: 0,
          summary: normalizedFailure(error)
        });
      }
    }
  } finally {
    options.signal?.removeEventListener("abort", abort);
  }
  return {
    schemaVersion: "1.0",
    status: aggregateStatus(results),
    startedAt,
    endedAt: wallClock(),
    cases: results
  };
}

function aggregateStatus(results: readonly ConformanceCaseResult[]): CertificationStatus {
  if (results.some((result) => result.status === "failed")) return "failed";
  if (results.some((result) => result.status === "inconclusive")) return "inconclusive";
  if (results.length > 0 && results.every((result) => result.status === "unsupported" || result.status === "not-run")) return "unsupported";
  if (results.some((result) => result.status === "withdrawn")) return "withdrawn";
  return "passed";
}

function normalizedFailure(error: unknown): string {
  const name = error instanceof Error ? error.name : "Error";
  return boundedSummary(name === "AbortError" ? "case aborted" : `case failed: ${name}`);
}

function boundedDuration(value: number): number {
  if (!Number.isFinite(value) || value < 0) throw new RangeError("conformance clock produced an invalid duration");
  return Math.min(86_400_000, Math.round(value * 1_000) / 1_000);
}

function boundedSummary(value: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 1_000) throw new RangeError("conformance summary must be in 1..1000 characters");
  return value.replace(/\/(?:Users|home)\/[^\s]+|[A-Za-z]:\\[^\s]+/gu, "<redacted-path>");
}
