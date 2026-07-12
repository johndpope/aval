export function collectSelfContainedReportSet(input: Readonly<{
  index: Readonly<{
    reports: readonly Readonly<{ id: string; path: string; sha256: string; byteLength: number; mediaType: string }>[];
    reviewRecord: Readonly<{ id: string; path: string; sha256: string; byteLength: number; mediaType: string }> | null;
  }>;
  indexBytes: Uint8Array;
  indexPath: string;
  referenceRoot: string;
  releaseRoot: string;
}>): Promise<Readonly<{
  reports: readonly Readonly<{ id: string; path: string; sha256: string; byteLength: number; mediaType: string }>[];
  artifacts: readonly Readonly<{ id: string; path: string; sha256: string; byteLength: number; mediaType: string }>[];
  reachable: ReadonlySet<string>;
}>>;
