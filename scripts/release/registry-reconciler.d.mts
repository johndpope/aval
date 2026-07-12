import type { PublicationOperation, RegistryPackageState } from "../../packages/certification/src/publication-ledger.js";
export function reconcileRegistryMutation(input: Readonly<{
  planned: PublicationOperation;
  mutate: () => void;
  readState: () => RegistryPackageState;
  certification: Readonly<{
    completePublicationOperation: (planned: PublicationOperation, observed: RegistryPackageState) => PublicationOperation;
    failPublicationOperation: (planned: PublicationOperation, observed?: RegistryPackageState) => PublicationOperation;
    markPublicationOperationAmbiguous: (planned: PublicationOperation, observed?: RegistryPackageState) => PublicationOperation;
  }>;
}>): Readonly<{ operation: PublicationOperation; error: unknown | null; reconciledAfterMutationError?: boolean }>;
