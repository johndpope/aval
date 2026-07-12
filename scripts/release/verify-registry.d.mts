import type { RegistryPackageState } from "../../packages/certification/src/publication-ledger.js";
export function verifyRegistryReleaseSet(input: Readonly<{
  releaseSet: Readonly<{ packages: readonly Readonly<{ name: string; registryIntegrity: string }>[] }>;
  tag: "next" | "latest";
  readState: (name: string, version: "1.0.0") => RegistryPackageState;
}>): readonly Readonly<{ name: string; version: "1.0.0"; registryIntegrity: string; tag: "next" | "latest" }>[];
