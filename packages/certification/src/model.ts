import type { CertificationStatus } from "./status.js";

export const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

export interface DigestReference {
  readonly id: string;
  readonly path: string;
  readonly sha256: string;
  readonly byteLength: number;
  readonly mediaType: string;
}

export interface CriterionResult {
  readonly id: string;
  readonly status: CertificationStatus;
  readonly evidence: readonly string[];
  readonly summary?: string;
}

export interface RuntimeEnvironment {
  readonly platformClass: string;
  readonly browser: {
    readonly product: string;
    readonly version: string;
    readonly build: string;
    readonly channel: string;
    readonly engineVersion: string;
    readonly flags: readonly string[];
    readonly profileClean: boolean;
  };
  readonly os: {
    readonly product: string;
    readonly version: string;
    readonly build: string;
    readonly architecture: string;
    readonly patchState: string;
  };
  readonly hardware: {
    readonly deviceClass: string;
    readonly cpu: string;
    readonly gpu: string;
    readonly driver: string;
    readonly physicalMemoryMiB: number;
    readonly virtualization: "none" | "virtualized" | "unknown";
    readonly decoderMode: "hardware" | "software" | "unknown";
  };
  readonly display: {
    readonly displayClass: string;
    readonly connection: string;
    readonly nativeWidth: number;
    readonly nativeHeight: number;
    readonly width: number;
    readonly height: number;
    readonly refreshMilliHz: number;
    readonly devicePixelRatioMilli: number;
    readonly colorMode: string;
    readonly hdr: boolean;
    readonly multiDisplay: boolean;
  };
  readonly power: {
    readonly source: "ac" | "battery" | "unknown";
    readonly mode: string;
    readonly chargeRange: string;
    readonly browserEnergyMode: string;
    readonly thermal: string;
    readonly backgroundLoad: string;
  };
  readonly capabilities: Readonly<Record<string, boolean | number | string>>;
}

export interface RuntimeScenarioResult {
  readonly id: string;
  readonly repetition: number;
  readonly seed: number;
  readonly status: CertificationStatus;
  readonly boundaryCount: number;
  readonly frameCount: number;
  readonly operationCount?: number;
  readonly headedOperationCount?: number;
  readonly formatUnderflows: number;
  readonly firstFailingOrdinal?: number;
  readonly ledgerDigest: string;
}

export interface RuntimeCertificationReport {
  readonly schemaVersion: "1.0";
  readonly reportKind: "runtime-scheduling";
  readonly reportId: string;
  readonly status: CertificationStatus;
  readonly candidateManifestDigest: string;
  readonly commit: string;
  readonly tree: string;
  readonly startedAt: string;
  readonly endedAt: string;
  readonly operatorRole: string;
  readonly reviewerIds: readonly string[];
  readonly environment: RuntimeEnvironment;
  readonly scenarios: readonly RuntimeScenarioResult[];
  readonly criteria: readonly CriterionResult[];
  readonly attachments: readonly DigestReference[];
  readonly supersedes?: string;
  readonly withdrawalReason?: string;
}

export interface DisplayCertificationReport {
  readonly schemaVersion: "1.0";
  readonly reportKind: "observed-display";
  readonly reportId: string;
  readonly status: CertificationStatus;
  readonly candidateManifestDigest: string;
  readonly runtimeReportId: string;
  readonly runtimeReportDigest: string;
  readonly runtimeReportStatus: "passed";
  readonly runtimeScenarioId: string;
  readonly runtimeScenarioRepetition: number;
  readonly runtimeScenarioLedgerDigest: string;
  readonly patternDigest: string;
  readonly method: "external-high-speed-capture" | "qualified-scanout-trace";
  readonly captureRateMilliHz: number;
  readonly measuredRefreshMilliHz: number;
  readonly minimumConfidenceMillionths: number;
  readonly startedAt: string;
  readonly endedAt: string;
  readonly observationCount: number;
  readonly refreshCount: number;
  readonly distinctAppearanceCount: number;
  readonly thresholdMicroseconds: number;
  readonly firstFailingRefreshOrdinal: number | null;
  readonly observationLedgerDigest: string;
  readonly captureProvenance: DisplayCaptureProvenance;
  readonly criteria: readonly CriterionResult[];
  readonly attachments: readonly DigestReference[];
}

export interface DisplayCaptureProvenance {
  readonly rawCaptureDigest: string;
  readonly extractor: Readonly<{ readonly tool: string; readonly version: string }>;
  readonly operatorRole: string;
  readonly reviewerIds: readonly string[];
}

export interface CandidateArtifact extends DigestReference {
  readonly role: string;
}

export interface CandidateBrowserPin {
  readonly playwrightBrowserManifestSha256: string;
  readonly browsers: Readonly<Record<"chromium" | "firefox" | "webkit", Readonly<{
    readonly revision: string;
    readonly engineVersion: string;
  }>>>;
}

export interface CandidateManifest {
  readonly schemaVersion: "1.0";
  readonly manifestKind: "candidate";
  readonly releaseVersion: "1.0.0";
  readonly releaseSetDigest: string;
  readonly commit: string;
  readonly tree: string;
  readonly cleanTree: true;
  readonly createdAt: string;
  readonly tools: Readonly<Record<string, string>>;
  readonly browserPin: CandidateBrowserPin;
  readonly artifacts: readonly CandidateArtifact[];
}

export interface ReleaseManifest {
  readonly schemaVersion: "1.0";
  readonly manifestKind: "release";
  readonly releaseVersion: "1.0.0";
  readonly candidateManifestDigest: string;
  readonly releaseSetDigest: string;
  readonly createdAt: string;
  readonly reports: readonly DigestReference[];
  readonly artifacts: readonly DigestReference[];
  readonly reviews: readonly { readonly id: string; readonly decision: "approved"; readonly evidenceDigest: string }[];
  readonly previousKnownGood: string;
  readonly rollbackTag: string;
}
