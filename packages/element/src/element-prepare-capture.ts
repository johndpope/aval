import type { ElementAssetGeneration } from "./asset-generation.js";
import type { ElementDesiredSnapshot } from "./element-desired-state.js";
import { AvalNotReadyError, avalAbortError } from "./errors.js";

/** Captures one invocation token; lane settlement can never migrate it. */
export async function capturePreparedSource(input: Readonly<{
  invocationSourceToken: number;
  settled: Promise<void>;
  current(): Readonly<ElementDesiredSnapshot>;
  active(): ElementAssetGeneration | null;
}>): Promise<ElementAssetGeneration> {
  await input.settled;
  const snapshot = input.current();
  if (snapshot.sourceToken !== input.invocationSourceToken) {
    throw avalAbortError("prepare source was superseded");
  }
  if ((snapshot.configuration?.sourceCandidates.length ?? 0) === 0) {
    throw new AvalNotReadyError("aval-player has no valid source candidates");
  }
  const asset = input.active();
  if (asset === null || snapshot.terminal || !snapshot.connected) {
    throw new AvalNotReadyError();
  }
  return asset;
}
