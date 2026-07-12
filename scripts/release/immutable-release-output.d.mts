export function prepareImmutableReleaseSetOutput(input: Readonly<{ output: string; index: string }>): Promise<Readonly<{
  finalOutput: string;
  finalIndex: string;
  targetRoot: string;
  stagedRoot: string;
  stagedOutput: string;
  stagedIndex: string;
  publish(): Promise<void>;
  dispose(): Promise<void>;
}>>;
