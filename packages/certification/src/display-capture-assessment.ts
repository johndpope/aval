import { displayMarkerFields, type DisplayPatternDefinition } from "./display-pattern.js";
import type { DisplayCaptureLedger, DisplayCaptureSample } from "./display-evidence-model.js";

export interface DisplayRefreshObservation {
  readonly ordinal: number;
  readonly timestampMicroseconds: number;
  readonly contentValue: number | null;
  readonly occurrenceValue: number | null;
  readonly blackDetected: boolean;
  readonly transparentUninitializedDetected: boolean;
}

export interface DisplayCaptureAssessment {
  readonly refreshes: readonly DisplayRefreshObservation[];
  readonly failures: readonly string[];
  readonly inconclusiveReasons: readonly string[];
}

const CALIBRATION_TARGETS = new Map<string, readonly [number, number, number]>([
  ["black", [0, 0, 0]],
  ["white", [255, 255, 255]],
  ["red", [255, 0, 0]],
  ["green", [0, 255, 0]],
  ["blue", [0, 0, 255]]
]);

export function assessDisplayCapture(ledger: DisplayCaptureLedger, pattern: DisplayPatternDefinition): DisplayCaptureAssessment {
  const failures: string[] = [];
  const inconclusive: string[] = [];
  validateCalibration(ledger, pattern, inconclusive);
  validateCaptureCadence(ledger, inconclusive);
  const groups = groupSamples(ledger.samples, inconclusive);
  const refreshes = decodeRefreshes(groups, ledger, pattern, failures, inconclusive);
  if (refreshes.length === 0) inconclusive.push("observations-empty");
  return Object.freeze({
    refreshes: Object.freeze(refreshes),
    failures: Object.freeze([...new Set(failures)]),
    inconclusiveReasons: Object.freeze([...new Set(inconclusive)])
  });
}

function validateCaptureCadence(ledger: DisplayCaptureLedger, inconclusive: string[]): void {
  const samples = ledger.samples;
  if (samples.length < 2) {
    inconclusive.push("capture-cadence-insufficient");
    return;
  }
  let priorTimestamp = -1;
  samples.forEach((sample, index) => {
    if (sample.captureOrdinal !== index) inconclusive.push("capture-ordinal-gap");
    if (sample.captureTimestampMicroseconds <= priorTimestamp) inconclusive.push("capture-clock-order");
    priorTimestamp = sample.captureTimestampMicroseconds;
  });
  const duration = samples.at(-1)!.captureTimestampMicroseconds - samples[0]!.captureTimestampMicroseconds;
  if (duration <= 0) return;
  const actualRateMilliHz = Math.round((samples.length - 1) * 1_000_000_000 / duration);
  const tolerance = Math.max(1_000, Math.round(ledger.captureRateMilliHz / 10));
  if (Math.abs(actualRateMilliHz - ledger.captureRateMilliHz) > tolerance) inconclusive.push("capture-rate-observation-mismatch");
  if (ledger.method === "external-high-speed-capture" && actualRateMilliHz + tolerance < ledger.measuredRefreshMilliHz * 4) inconclusive.push("capture-rate-observed-below-four-times-refresh");
}

function groupSamples(samples: readonly DisplayCaptureSample[], inconclusive: string[]): ReadonlyMap<number, readonly DisplayCaptureSample[]> {
  const mutable = new Map<number, DisplayCaptureSample[]>();
  let priorRefresh = -1;
  for (const sample of samples) {
    if (sample.refreshOrdinal < priorRefresh) inconclusive.push("refresh-order");
    const group = mutable.get(sample.refreshOrdinal) ?? [];
    group.push(sample);
    mutable.set(sample.refreshOrdinal, group);
    priorRefresh = sample.refreshOrdinal;
  }
  return new Map([...mutable].map(([ordinal, group]) => [ordinal, Object.freeze(group)]));
}

function decodeRefreshes(
  groups: ReadonlyMap<number, readonly DisplayCaptureSample[]>,
  ledger: DisplayCaptureLedger,
  pattern: DisplayPatternDefinition,
  failures: string[],
  inconclusive: string[]
): DisplayRefreshObservation[] {
  const result: DisplayRefreshObservation[] = [];
  let markerOrigin: number | null = null;
  let priorOrdinal = -1;
  const minimumInteriorSamples = ledger.method === "external-high-speed-capture"
    ? Math.max(1, Math.floor(ledger.captureRateMilliHz / ledger.measuredRefreshMilliHz) - 1)
    : 1;
  const lastOrdinal = [...groups.keys()].at(-1);
  for (const [ordinal, group] of groups) {
    if (priorOrdinal < 0 && ordinal !== 0) inconclusive.push("refresh-origin-not-zero");
    if (priorOrdinal >= 0 && ordinal !== priorOrdinal + 1) inconclusive.push("refresh-ordinal-gap");
    if (ordinal > 0 && ordinal !== lastOrdinal && group.length < minimumInteriorSamples) inconclusive.push(`refresh-capture-density:${String(ordinal)}`);
    const markerValues = group.filter((sample) => validCaptureMarker(sample, pattern)).map(({ captureMarkerValue }) => captureMarkerValue);
    if (markerValues.length !== group.length || markerValues.length === 0 || new Set(markerValues).size !== 1) inconclusive.push(`capture-marker-ambiguous:${String(ordinal)}`);
    markerOrigin ??= markerValues[0] ?? null;
    if (markerOrigin !== null) {
      const expectedMarker = displayMarkerFields(markerOrigin + ordinal, pattern).value;
      if (markerValues.some((value) => value !== expectedMarker)) inconclusive.push(`capture-marker-sequence:${String(ordinal)}`);
    }
    const decoded = group.filter((sample) => !sample.markerAmbiguous && sample.confidenceMillionths >= ledger.minimumConfidenceMillionths && validContentMarkers(sample, pattern));
    if (decoded.length !== group.length || decoded.length === 0) inconclusive.push(`refresh-marker-ambiguous:${String(ordinal)}`);
    const contents = new Set(decoded.map(({ contentValue }) => contentValue));
    const occurrences = new Set(decoded.map(({ occurrenceValue }) => occurrenceValue));
    if (contents.size > 1 || occurrences.size > 1) inconclusive.push(`refresh-marker-conflict:${String(ordinal)}`);
    const blackDetected = group.some(({ blackDetected }) => blackDetected);
    const transparentUninitializedDetected = group.some(({ transparentUninitializedDetected }) => transparentUninitializedDetected);
    if (blackDetected && transparentUninitializedDetected) failures.push(`display-invalid-pixel-classification:${String(ordinal)}`);
    result.push(Object.freeze({
      ordinal,
      timestampMicroseconds: group[0]!.captureTimestampMicroseconds,
      contentValue: decoded[0]?.contentValue ?? null,
      occurrenceValue: decoded[0]?.occurrenceValue ?? null,
      blackDetected,
      transparentUninitializedDetected
    }));
    priorOrdinal = ordinal;
  }
  return result;
}

function validCaptureMarker(sample: DisplayCaptureSample, pattern: DisplayPatternDefinition): boolean {
  const fields = displayMarkerFields(sample.captureMarkerValue, pattern);
  return sample.captureMarkerComplement === fields.complement && sample.captureMarkerParity === fields.parity;
}

function validContentMarkers(sample: DisplayCaptureSample, pattern: DisplayPatternDefinition): boolean {
  if (sample.contentValue === null || sample.contentComplement === null || sample.contentParity === null || sample.occurrenceValue === null || sample.occurrenceComplement === null || sample.occurrenceParity === null) return false;
  const content = displayMarkerFields(sample.contentValue, pattern);
  const occurrence = displayMarkerFields(sample.occurrenceValue, pattern);
  return sample.contentComplement === content.complement && sample.contentParity === content.parity && sample.occurrenceComplement === occurrence.complement && sample.occurrenceParity === occurrence.parity;
}

function validateCalibration(ledger: DisplayCaptureLedger, pattern: DisplayPatternDefinition, inconclusive: string[]): void {
  if (ledger.calibration.focusScoreMillionths < 990_000) inconclusive.push("calibration-focus");
  if (ledger.calibration.regionCoverageMillionths < 990_000) inconclusive.push("calibration-region");
  if (ledger.calibration.exposureClippedSamples !== 0) inconclusive.push("calibration-exposure");
  const byId = new Map(ledger.calibration.patches.map((patch) => [patch.id, patch]));
  for (const id of pattern.calibrationPatchIds) {
    const patch = byId.get(id);
    const target = CALIBRATION_TARGETS.get(id)!;
    if (patch === undefined || patch.confidenceMillionths < 990_000 || Math.abs(patch.red - target[0]) > 16 || Math.abs(patch.green - target[1]) > 16 || Math.abs(patch.blue - target[2]) > 16) inconclusive.push(`calibration-patch:${id}`);
  }
  if (byId.size !== pattern.calibrationPatchIds.length) inconclusive.push("calibration-patch-cardinality");
}
