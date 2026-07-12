export function prepareImmutableCandidateOutput(input: Readonly<{ candidate: string; legacyIndex: string }>): Promise<Readonly<{
  finalCandidate: string;
  finalLegacyIndex: string;
  temporaryRoot: string;
  stagedCandidate: string;
  temporaryIndex: string;
  publish(): Promise<void>;
  dispose(): Promise<void>;
}>>;
