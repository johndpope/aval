import type { VerifiedArtifact } from "./artifact-verifier.js";
import {
  DISPLAY_CAPTURE_SAMPLE_KEYS,
  validateDisplayCaptureLedger,
  type DisplayCaptureLedger
} from "./display-evidence-model.js";
import type { DisplayCertificationReport } from "./model.js";
import { parseCanonicalBundleJson } from "./report-bundle-artifacts.js";
import type { ReportBundlePolicy } from "./report-bundle-policy.js";
import { DISPLAY_RAW_CAPTURE_ATTACHMENT_ID } from "./scenario-contract.js";
import { CertificationValidationError } from "./status.js";

export function validateRawCaptureEvidence(
  display: DisplayCertificationReport,
  artifact: VerifiedArtifact,
  observationLedger: DisplayCaptureLedger,
  policy: ReportBundlePolicy
): void {
  if (display.method === "external-high-speed-capture") {
    validateExternalCaptureContainer(artifact);
    return;
  }
  const bytes = artifact.bytes;
  if (bytes === null) throw rawCaptureError("qualified trace bytes were not retained");
  const trace = parseCanonicalBundleJson(bytes, rawCapturePath(), policy.maximumAttachmentBytes);
  if (trace === null || typeof trace !== "object" || Array.isArray(trace)) throw rawCaptureError("qualified trace must be an object");
  const value = trace as Record<string, unknown>;
  const allowed = new Set(["schemaVersion", "traceKind", "candidateManifestDigest", "provider", "providerVersion", "extractor", "operatorRole", "reviewerIds", "recordCount", "records"]);
  if (Object.keys(value).some((key) => !allowed.has(key)) || [...allowed].some((key) => !(key in value))) throw rawCaptureError("qualified trace envelope is not exact");
  if (value.schemaVersion !== "1.0" || value.traceKind !== "qualified-scanout-trace" || value.candidateManifestDigest !== display.candidateManifestDigest) throw rawCaptureError("qualified trace identity mismatch");
  if (typeof value.provider !== "string" || typeof value.providerVersion !== "string" || policy.allowedQualifiedScanoutProviders?.get(value.provider) !== value.providerVersion) throw rawCaptureError("scanout trace provider is not qualified by policy");
  requireTraceProvenance(value, display);
  if (!Number.isSafeInteger(value.recordCount) || (value.recordCount as number) <= 0 || !Array.isArray(value.records) || value.records.length !== value.recordCount || value.records.length > 2_000_000) throw rawCaptureError("qualified trace record count is invalid");
  const traceLedger = validateDisplayCaptureLedger({
    schemaVersion: "1.0",
    ledgerKind: "observed-display-capture",
    candidateManifestDigest: display.candidateManifestDigest,
    runtimeReportDigest: display.runtimeReportDigest,
    runtimeScenarioId: display.runtimeScenarioId,
    runtimeScenarioRepetition: display.runtimeScenarioRepetition,
    runtimeScenarioLedgerDigest: display.runtimeScenarioLedgerDigest,
    patternDigest: display.patternDigest,
    method: display.method,
    captureRateMilliHz: display.captureRateMilliHz,
    measuredRefreshMilliHz: display.measuredRefreshMilliHz,
    minimumConfidenceMillionths: display.minimumConfidenceMillionths,
    captureProvenance: display.captureProvenance,
    calibration: observationLedger.calibration,
    samples: value.records
  });
  const reconstructed = traceLedger.samples.length === observationLedger.samples.length &&
    traceLedger.samples.every((record, index) => DISPLAY_CAPTURE_SAMPLE_KEYS.every((key) => record[key] === observationLedger.samples[index]?.[key]));
  if (!reconstructed) throw rawCaptureError("qualified trace records do not reconstruct the observation ledger");
}

export function requireCaptureAuthority(display: DisplayCertificationReport, policy: ReportBundlePolicy): void {
  const provenance = display.captureProvenance;
  if (policy.allowedDisplayCaptureExtractors?.get(provenance.extractor.tool) !== provenance.extractor.version) throw new CertificationValidationError("$display.captureProvenance.extractor", "capture extractor is not qualified by policy");
  if (!policy.allowedDisplayCaptureOperatorRoles?.has(provenance.operatorRole)) throw new CertificationValidationError("$display.captureProvenance.operatorRole", "capture operator role is not qualified by policy");
  const qualifiedReviewers = policy.allowedDisplayCaptureReviewerIds;
  if (qualifiedReviewers === undefined || qualifiedReviewers.size < 2 || !sameStringSet(provenance.reviewerIds, qualifiedReviewers)) {
    throw new CertificationValidationError("$display.captureProvenance.reviewerIds", "capture reviewers do not match the complete qualified policy set");
  }
}

export function requireRawCaptureMediaType(method: DisplayCertificationReport["method"], mediaType: string): void {
  const allowed = method === "external-high-speed-capture"
    ? new Set(["video/mp4", "video/quicktime"])
    : new Set(["application/json", "application/jsonl"]);
  if (!allowed.has(mediaType)) throw new CertificationValidationError(`${rawCapturePath()}.mediaType`, "raw capture media type does not match the independent method");
}

function requireTraceProvenance(value: Record<string, unknown>, display: DisplayCertificationReport): void {
  const extractor = value.extractor as Record<string, unknown>;
  const exactExtractor = extractor !== null && typeof extractor === "object" && !Array.isArray(extractor) &&
    Object.keys(extractor).sort().join(",") === "tool,version" &&
    extractor.tool === display.captureProvenance.extractor.tool && extractor.version === display.captureProvenance.extractor.version;
  if (!exactExtractor || value.operatorRole !== display.captureProvenance.operatorRole || !sameOrderedStrings(value.reviewerIds, display.captureProvenance.reviewerIds)) {
    throw rawCaptureError("qualified trace capture provenance mismatch");
  }
}

function validateExternalCaptureContainer(artifact: VerifiedArtifact): void {
  if (artifact.reference.byteLength < 4 * 1024) throw rawCaptureError("raw external capture is too small to contain recorded media");
  const boxes = parseTopLevelIsoBoxes(artifact);
  const ftyp = boxes[0];
  if (ftyp?.type !== "ftyp" || ftyp.size < ftyp.headerSize + 8) throw rawCaptureError("raw external capture lacks a complete ISO ftyp box");
  const mdat = boxes.find(({ type }) => type === "mdat");
  if (mdat === undefined || mdat.size - mdat.headerSize < 1024) throw rawCaptureError("raw external capture lacks a nontrivial media-data box");
  const moov = boxes.find(({ type }) => type === "moov");
  if (moov === undefined) throw rawCaptureError("raw external capture lacks a complete movie metadata box");
  const movie = readArtifactWindow(artifact, moov.offset, moov.size);
  if (movie === null) throw rawCaptureError("movie metadata exceeds the bounded inspection window");
  validateMovieSampleTable(movie, moov.headerSize);
}

interface IsoBox { readonly type: string; readonly offset: number; readonly size: number; readonly headerSize: number }

function parseTopLevelIsoBoxes(artifact: VerifiedArtifact): readonly IsoBox[] {
  const boxes: IsoBox[] = [];
  let offset = 0;
  while (offset < artifact.reference.byteLength) {
    if (boxes.length >= 1024) throw rawCaptureError("raw external capture has too many top-level boxes");
    const header = readArtifactWindow(artifact, offset, 16) ?? readArtifactWindow(artifact, offset, 8);
    if (header === null || header.byteLength < 8) throw rawCaptureError("raw external capture has a truncated top-level box header");
    const parsed = parseBoxHeader(header, 0, artifact.reference.byteLength - offset);
    const size = parsed.size === 0 ? artifact.reference.byteLength - offset : parsed.size;
    if (size < parsed.headerSize || offset + size > artifact.reference.byteLength) throw rawCaptureError("raw external capture top-level box exceeds file bounds");
    boxes.push(Object.freeze({ type: parsed.type, offset, size, headerSize: parsed.headerSize }));
    offset += size;
  }
  if (offset !== artifact.reference.byteLength) throw rawCaptureError("raw external capture top-level boxes do not cover the file exactly");
  return Object.freeze(boxes);
}

function readArtifactWindow(artifact: VerifiedArtifact, offset: number, length: number): Uint8Array | null {
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > artifact.reference.byteLength) return null;
  if (offset + length <= artifact.prefix.byteLength) return artifact.prefix.subarray(offset, offset + length);
  const suffixStart = artifact.reference.byteLength - artifact.suffix.byteLength;
  if (offset >= suffixStart) return artifact.suffix.subarray(offset - suffixStart, offset - suffixStart + length);
  return null;
}

function validateMovieSampleTable(movie: Uint8Array, headerSize: number): void {
  const moov = parseMemoryBoxes(movie, headerSize, movie.byteLength);
  const tracks = moov.filter(({ type }) => type === "trak");
  if (tracks.length < 1) throw rawCaptureError("movie metadata has no track");
  const validTrack = tracks.some((track) => {
    const mdia = childBox(movie, track, "mdia");
    const minf = mdia === null ? null : childBox(movie, mdia, "minf");
    const stbl = minf === null ? null : childBox(movie, minf, "stbl");
    if (stbl === null) return false;
    const samples = parseMemoryBoxes(movie, stbl.offset + stbl.headerSize, stbl.offset + stbl.size);
    const stsd = samples.find(({ type }) => type === "stsd");
    const stts = samples.find(({ type }) => type === "stts");
    const stsc = samples.find(({ type }) => type === "stsc");
    const stsz = samples.find(({ type }) => type === "stsz");
    const stco = samples.find(({ type }) => type === "stco" || type === "co64");
    return stsd !== undefined && fullBoxCount(movie, stsd, 4) > 0 &&
      stts !== undefined && fullBoxCount(movie, stts, 4) > 0 &&
      stsc !== undefined && fullBoxCount(movie, stsc, 4) > 0 &&
      stsz !== undefined && fullBoxCount(movie, stsz, 8) > 0 &&
      stco !== undefined && fullBoxCount(movie, stco, 4) > 0;
  });
  if (!validTrack) throw rawCaptureError("movie metadata has no bounded nonempty sample table");
}

function childBox(bytes: Uint8Array, parent: IsoBox, type: string): IsoBox | null {
  return parseMemoryBoxes(bytes, parent.offset + parent.headerSize, parent.offset + parent.size).find((box) => box.type === type) ?? null;
}

function parseMemoryBoxes(bytes: Uint8Array, start: number, end: number): readonly IsoBox[] {
  const boxes: IsoBox[] = [];
  let offset = start;
  while (offset < end) {
    if (boxes.length >= 4096 || offset + 8 > end) throw rawCaptureError("movie metadata box structure is invalid");
    const parsed = parseBoxHeader(bytes, offset, end - offset);
    const size = parsed.size === 0 ? end - offset : parsed.size;
    if (size < parsed.headerSize || offset + size > end) throw rawCaptureError("movie metadata child box exceeds bounds");
    boxes.push(Object.freeze({ type: parsed.type, offset, size, headerSize: parsed.headerSize }));
    offset += size;
  }
  return Object.freeze(boxes);
}

function parseBoxHeader(bytes: Uint8Array, offset: number, available: number): Readonly<{ type: string; size: number; headerSize: number }> {
  if (available < 8 || offset + 8 > bytes.byteLength) throw rawCaptureError("ISO box header is truncated");
  const size32 = uint32(bytes, offset);
  const type = String.fromCharCode(bytes[offset + 4]!, bytes[offset + 5]!, bytes[offset + 6]!, bytes[offset + 7]!);
  if (!/^[\x20-\x7e]{4}$/u.test(type)) throw rawCaptureError("ISO box type is invalid");
  if (size32 !== 1) return Object.freeze({ type, size: size32, headerSize: 8 });
  if (available < 16 || offset + 16 > bytes.byteLength) throw rawCaptureError("extended ISO box header is truncated");
  const size64 = (BigInt(uint32(bytes, offset + 8)) << 32n) | BigInt(uint32(bytes, offset + 12));
  if (size64 > BigInt(Number.MAX_SAFE_INTEGER)) throw rawCaptureError("ISO box size exceeds safe range");
  return Object.freeze({ type, size: Number(size64), headerSize: 16 });
}

function fullBoxCount(bytes: Uint8Array, box: IsoBox, payloadOffset: number): number {
  const offset = box.offset + box.headerSize + payloadOffset;
  return offset + 4 <= box.offset + box.size ? uint32(bytes, offset) : 0;
}

function uint32(bytes: Uint8Array, offset: number): number {
  if (offset + 4 > bytes.byteLength) return 0;
  return bytes[offset]! * 0x1000000 + bytes[offset + 1]! * 0x10000 + bytes[offset + 2]! * 0x100 + bytes[offset + 3]!;
}

function sameStringSet(left: readonly string[], right: ReadonlySet<string>): boolean {
  return left.length === right.size && left.every((value) => right.has(value));
}

function sameOrderedStrings(value: unknown, expected: readonly string[]): boolean {
  return Array.isArray(value) && value.length === expected.length && value.every((item, index) => item === expected[index]);
}

function rawCapturePath(): string { return `$display.attachments.${DISPLAY_RAW_CAPTURE_ATTACHMENT_ID}`; }
function rawCaptureError(message: string): CertificationValidationError { return new CertificationValidationError(rawCapturePath(), message); }
