import { SHA256_PATTERN, type DisplayCaptureProvenance } from "./model.js";

export interface DisplayCaptureSample {
  readonly captureOrdinal: number;
  readonly captureTimestampMicroseconds: number;
  readonly captureMarkerValue: number;
  readonly captureMarkerComplement: number;
  readonly captureMarkerParity: number;
  readonly refreshOrdinal: number;
  readonly contentValue: number | null;
  readonly contentComplement: number | null;
  readonly contentParity: number | null;
  readonly occurrenceValue: number | null;
  readonly occurrenceComplement: number | null;
  readonly occurrenceParity: number | null;
  readonly confidenceMillionths: number;
  readonly markerAmbiguous: boolean;
  readonly blackDetected: boolean;
  readonly transparentUninitializedDetected: boolean;
}

export interface DisplayCaptureLedger {
  readonly schemaVersion: "1.0";
  readonly ledgerKind: "observed-display-capture";
  readonly candidateManifestDigest: string;
  readonly runtimeReportDigest: string;
  readonly runtimeScenarioId: string;
  readonly runtimeScenarioRepetition: number;
  readonly runtimeScenarioLedgerDigest: string;
  readonly patternDigest: string;
  readonly method: "external-high-speed-capture" | "qualified-scanout-trace";
  readonly captureRateMilliHz: number;
  readonly measuredRefreshMilliHz: number;
  readonly minimumConfidenceMillionths: number;
  readonly captureProvenance: DisplayCaptureProvenance;
  readonly calibration: Readonly<{
    readonly focusScoreMillionths: number;
    readonly regionCoverageMillionths: number;
    readonly exposureClippedSamples: number;
    readonly patches: readonly Readonly<{
      readonly id: string;
      readonly red: number;
      readonly green: number;
      readonly blue: number;
      readonly confidenceMillionths: number;
    }>[];
  }>;
  readonly samples: readonly DisplayCaptureSample[];
}

const ROOT_KEYS = [
  "schemaVersion", "ledgerKind", "candidateManifestDigest", "runtimeReportDigest",
  "runtimeScenarioId", "runtimeScenarioRepetition", "runtimeScenarioLedgerDigest",
  "patternDigest", "method", "captureRateMilliHz", "measuredRefreshMilliHz",
  "minimumConfidenceMillionths", "captureProvenance", "calibration", "samples"
] as const;

export const DISPLAY_CAPTURE_SAMPLE_KEYS = Object.freeze([
  "captureOrdinal", "captureTimestampMicroseconds", "captureMarkerValue",
  "captureMarkerComplement", "captureMarkerParity", "refreshOrdinal", "contentValue",
  "contentComplement", "contentParity", "occurrenceValue", "occurrenceComplement",
  "occurrenceParity", "confidenceMillionths", "markerAmbiguous", "blackDetected",
  "transparentUninitializedDetected"
] as const);

export function validateDisplayCaptureLedger(input: unknown): DisplayCaptureLedger {
  const root = exactRecord(input, ROOT_KEYS, "$capture");
  literal(root.schemaVersion, "1.0", "$capture.schemaVersion");
  literal(root.ledgerKind, "observed-display-capture", "$capture.ledgerKind");
  return Object.freeze({
    schemaVersion: "1.0",
    ledgerKind: "observed-display-capture",
    candidateManifestDigest: digest(root.candidateManifestDigest, "$capture.candidateManifestDigest"),
    runtimeReportDigest: digest(root.runtimeReportDigest, "$capture.runtimeReportDigest"),
    runtimeScenarioId: identifier(root.runtimeScenarioId, "$capture.runtimeScenarioId"),
    runtimeScenarioRepetition: boundedInteger(root.runtimeScenarioRepetition, "$capture.runtimeScenarioRepetition", 1, 3),
    runtimeScenarioLedgerDigest: digest(root.runtimeScenarioLedgerDigest, "$capture.runtimeScenarioLedgerDigest"),
    patternDigest: digest(root.patternDigest, "$capture.patternDigest"),
    method: enumeration(root.method, ["external-high-speed-capture", "qualified-scanout-trace"] as const, "$capture.method"),
    captureRateMilliHz: positiveInteger(root.captureRateMilliHz, "$capture.captureRateMilliHz"),
    measuredRefreshMilliHz: positiveInteger(root.measuredRefreshMilliHz, "$capture.measuredRefreshMilliHz"),
    minimumConfidenceMillionths: boundedInteger(root.minimumConfidenceMillionths, "$capture.minimumConfidenceMillionths", 0, 1_000_000),
    captureProvenance: parseCaptureProvenance(root.captureProvenance, "$capture.captureProvenance"),
    calibration: parseCalibration(root.calibration),
    samples: Object.freeze(array(root.samples, "$capture.samples", 2_000_000).map(parseSample))
  });
}

export function parseCaptureProvenance(value: unknown, path: string): DisplayCaptureProvenance {
  const provenance = exactRecord(value, ["rawCaptureDigest", "extractor", "operatorRole", "reviewerIds"], path);
  const extractor = exactRecord(provenance.extractor, ["tool", "version"], `${path}.extractor`);
  const reviewerIds = array(provenance.reviewerIds, `${path}.reviewerIds`, 16).map((reviewer, index) => identifier(reviewer, `${path}.reviewerIds[${String(index)}]`));
  if (reviewerIds.length < 1 || new Set(reviewerIds).size !== reviewerIds.length) throw new TypeError(`${path}.reviewerIds must contain unique qualified reviewers`);
  return Object.freeze({
    rawCaptureDigest: digest(provenance.rawCaptureDigest, `${path}.rawCaptureDigest`),
    extractor: Object.freeze({
      tool: identifier(extractor.tool, `${path}.extractor.tool`),
      version: identifier(extractor.version, `${path}.extractor.version`)
    }),
    operatorRole: identifier(provenance.operatorRole, `${path}.operatorRole`),
    reviewerIds: Object.freeze(reviewerIds)
  });
}

function parseCalibration(value: unknown): DisplayCaptureLedger["calibration"] {
  const path = "$capture.calibration";
  const calibration = exactRecord(value, ["focusScoreMillionths", "regionCoverageMillionths", "exposureClippedSamples", "patches"], path);
  const patches = array(calibration.patches, `${path}.patches`, 16).map((input, index) => {
    const patchPath = `${path}.patches[${String(index)}]`;
    const patch = exactRecord(input, ["id", "red", "green", "blue", "confidenceMillionths"], patchPath);
    return Object.freeze({
      id: identifier(patch.id, `${patchPath}.id`),
      red: boundedInteger(patch.red, `${patchPath}.red`, 0, 255),
      green: boundedInteger(patch.green, `${patchPath}.green`, 0, 255),
      blue: boundedInteger(patch.blue, `${patchPath}.blue`, 0, 255),
      confidenceMillionths: boundedInteger(patch.confidenceMillionths, `${patchPath}.confidenceMillionths`, 0, 1_000_000)
    });
  });
  return Object.freeze({
    focusScoreMillionths: boundedInteger(calibration.focusScoreMillionths, `${path}.focusScoreMillionths`, 0, 1_000_000),
    regionCoverageMillionths: boundedInteger(calibration.regionCoverageMillionths, `${path}.regionCoverageMillionths`, 0, 1_000_000),
    exposureClippedSamples: nonnegativeInteger(calibration.exposureClippedSamples, `${path}.exposureClippedSamples`),
    patches: Object.freeze(patches)
  });
}

function parseSample(value: unknown, index: number): DisplayCaptureSample {
  const path = `$capture.samples[${String(index)}]`;
  const sample = exactRecord(value, DISPLAY_CAPTURE_SAMPLE_KEYS, path);
  return Object.freeze({
    captureOrdinal: nonnegativeInteger(sample.captureOrdinal, `${path}.captureOrdinal`),
    captureTimestampMicroseconds: nonnegativeInteger(sample.captureTimestampMicroseconds, `${path}.captureTimestampMicroseconds`),
    captureMarkerValue: boundedInteger(sample.captureMarkerValue, `${path}.captureMarkerValue`, 0, 65_535),
    captureMarkerComplement: boundedInteger(sample.captureMarkerComplement, `${path}.captureMarkerComplement`, 0, 65_535),
    captureMarkerParity: boundedInteger(sample.captureMarkerParity, `${path}.captureMarkerParity`, 0, 1),
    refreshOrdinal: nonnegativeInteger(sample.refreshOrdinal, `${path}.refreshOrdinal`),
    contentValue: nullableBounded(sample.contentValue, `${path}.contentValue`, 65_535),
    contentComplement: nullableBounded(sample.contentComplement, `${path}.contentComplement`, 65_535),
    contentParity: nullableBounded(sample.contentParity, `${path}.contentParity`, 1),
    occurrenceValue: nullableBounded(sample.occurrenceValue, `${path}.occurrenceValue`, 65_535),
    occurrenceComplement: nullableBounded(sample.occurrenceComplement, `${path}.occurrenceComplement`, 65_535),
    occurrenceParity: nullableBounded(sample.occurrenceParity, `${path}.occurrenceParity`, 1),
    confidenceMillionths: boundedInteger(sample.confidenceMillionths, `${path}.confidenceMillionths`, 0, 1_000_000),
    markerAmbiguous: booleanValue(sample.markerAmbiguous, `${path}.markerAmbiguous`),
    blackDetected: booleanValue(sample.blackDetected, `${path}.blackDetected`),
    transparentUninitializedDetected: booleanValue(sample.transparentUninitializedDetected, `${path}.transparentUninitializedDetected`)
  });
}

function exactRecord(value: unknown, keys: readonly string[], path: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${path} must be an object`);
  const record = value as Record<string, unknown>;
  const allowed = new Set(keys);
  for (const key of Object.keys(record)) if (!allowed.has(key)) throw new TypeError(`${path}.${key} is unknown`);
  for (const key of keys) if (!(key in record)) throw new TypeError(`${path}.${key} is required`);
  return record;
}

function array(value: unknown, path: string, maximum: number): readonly unknown[] {
  if (!Array.isArray(value) || value.length > maximum) throw new TypeError(`${path} must be an array of at most ${String(maximum)} items`);
  return value;
}

function nonnegativeInteger(value: unknown, path: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new TypeError(`${path} must be a nonnegative safe integer`);
  return value as number;
}

function positiveInteger(input: unknown, path: string): number {
  const value = nonnegativeInteger(input, path);
  if (value === 0) throw new TypeError(`${path} must be positive`);
  return value;
}

function boundedInteger(value: unknown, path: string, minimum: number, maximum: number): number {
  const result = nonnegativeInteger(value, path);
  if (result < minimum || result > maximum) throw new TypeError(`${path} is outside bounds`);
  return result;
}

function nullableBounded(value: unknown, path: string, maximum: number): number | null {
  return value === null ? null : boundedInteger(value, path, 0, maximum);
}

function digest(value: unknown, path: string): string {
  if (typeof value !== "string" || !SHA256_PATTERN.test(value)) throw new TypeError(`${path} is invalid`);
  return value;
}

function identifier(value: unknown, path: string): string {
  if (typeof value !== "string" || !/^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$/u.test(value)) throw new TypeError(`${path} is invalid`);
  return value;
}

function enumeration<const T extends readonly string[]>(value: unknown, values: T, path: string): T[number] {
  if (typeof value !== "string" || !values.includes(value)) throw new TypeError(`${path} is invalid`);
  return value as T[number];
}

function booleanValue(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new TypeError(`${path} must be boolean`);
  return value;
}

function literal(value: unknown, expected: string, path: string): void {
  if (value !== expected) throw new TypeError(`${path} must be ${expected}`);
}
