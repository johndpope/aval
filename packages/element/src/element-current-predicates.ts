import type { ElementAssetGeneration } from "./asset-generation.js";
import type { ElementDesiredSnapshot } from "./element-desired-state.js";
import type {
  ElementResumeCommandKey,
  ElementStateCommandKey
} from "./element-runtime-effects.js";

export function elementRuntimeEffectCurrent(input: Readonly<{
  desired: Readonly<ElementDesiredSnapshot>;
  expected: Readonly<ElementDesiredSnapshot>;
  active: ElementAssetGeneration | null;
  asset: ElementAssetGeneration;
}>): boolean {
  return !input.desired.terminal && input.desired.connected &&
    input.desired.revision === input.expected.revision &&
    input.desired.sourceToken === input.expected.sourceToken &&
    input.active === input.asset;
}

export function elementSourceCurrent(
  desired: Readonly<ElementDesiredSnapshot>,
  sourceToken: number
): boolean {
  return !desired.terminal && desired.sourceToken === sourceToken;
}

export function elementResumeCurrent(input: Readonly<{
  desired: Readonly<ElementDesiredSnapshot>;
  active: ElementAssetGeneration | null;
  asset: ElementAssetGeneration;
  key: Readonly<ElementResumeCommandKey>;
}>): boolean {
  return input.active === input.asset &&
    input.desired.sourceToken === input.key.sourceToken &&
    input.desired.playSequence === input.key.playSequence &&
    input.desired.manualPlaying && input.desired.effectivelyVisible;
}

export function elementStateCurrent(input: Readonly<{
  desired: Readonly<ElementDesiredSnapshot>;
  active: ElementAssetGeneration | null;
  asset: ElementAssetGeneration;
  key: Readonly<ElementStateCommandKey>;
}>): boolean {
  const intent = input.desired.stateIntent;
  return input.active === input.asset && !input.desired.terminal &&
    input.desired.sourceToken === input.key.sourceToken && intent !== null &&
    intent.name === input.key.name && intent.sequence === input.key.sequence;
}
