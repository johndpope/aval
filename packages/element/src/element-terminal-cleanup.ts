import type { ElementOwnershipSnapshot } from "./element-ownership-ledger.js";
import type {
  RenderedMotionCleanupReceipt,
  RenderedMotionElementOwnershipSnapshot,
  RenderedMotionTerminalCleanupProof
} from "./public-types.js";

export function publicElementOwnership(
  value: Readonly<ElementOwnershipSnapshot>
): Readonly<RenderedMotionElementOwnershipSnapshot> {
  return Object.freeze({ ...value });
}

export function createTerminalCleanupProof(input: Readonly<{
  sourceGeneration: number;
  cleanup: Readonly<RenderedMotionCleanupReceipt> | null;
  ownership: Readonly<ElementOwnershipSnapshot>;
  mechanicsCompleted?: boolean;
}>): Readonly<RenderedMotionTerminalCleanupProof> {
  const elementOwnership = publicElementOwnership(input.ownership);
  const sourceCleanupCompleted = input.sourceGeneration === 0 || (
    input.cleanup?.sourceGeneration === input.sourceGeneration &&
    input.cleanup.completed
  );
  return Object.freeze({
    completed: input.mechanicsCompleted !== false &&
      sourceCleanupCompleted && elementOwnership.completed &&
      elementOwnership.failedReleaseCount === 0,
    sourceCleanupCompleted,
    elementOwnership
  });
}

export class ElementCleanupIncompleteError extends Error {
  public constructor() {
    super("rendered-motion element cleanup was incomplete");
    this.name = "OperationError";
  }
}
