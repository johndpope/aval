import { gradeRuntimeScenarioLedger } from "./runtime-scenario-grader.js";
import { parseRuntimeScenarioLedger, type RuntimeScenarioLedgerExpectation } from "./runtime-scenario-parser.js";

export { deriveRuntimeDisplaySchedule, REQUIRED_ROUTE_CLASSES } from "./runtime-scenario-grader.js";
export type { RuntimeDisplayScheduleEntry } from "./runtime-scenario-grader.js";
export { runtimeFixtureModelFromManifest } from "./runtime-fixture-model.js";
export type { RuntimeFixtureModel } from "./runtime-fixture-model.js";
export type {
  RawRuntimeCursor,
  RawRuntimeGraphEffect,
  RawRuntimeGraphEvent,
  RawRuntimeOperationEvent,
  RawRuntimeResourceEvent,
  RawRuntimeScenarioFrame,
  RuntimeScenarioLedger,
  RuntimeScenarioLedgerEvaluation,
  RuntimeScenarioLedgerExpectation
} from "./runtime-scenario-parser.js";

/** One public evaluator: strict raw parsing followed by fixture-authoritative grading. */
export function evaluateRuntimeScenarioLedger(input: unknown, expected: RuntimeScenarioLedgerExpectation = {}) {
  const ledger = parseRuntimeScenarioLedger(input);
  return Object.freeze({ ledger, evaluation: gradeRuntimeScenarioLedger(ledger, expected) });
}
