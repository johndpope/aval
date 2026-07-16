import type { ElementConfiguration } from "./element-configuration.js";
import type { ElementController } from "./element-controller.js";
import type {
  ElementDesiredSnapshot,
  ElementDesiredState
} from "./element-desired-state.js";
import type { ElementCapturedSource } from "./element-generation-factory.js";
import type { ShadowLayerOwner } from "./shadow-layers.js";

/** Mutable source effect data only; serialization remains in controller/actor. */
export class ElementSourceEffectState {
  public captured: Readonly<ElementCapturedSource> | null = null;
  public appliedToken = -1;
  public appliedCreate: boolean | null = null;
  public operation: Promise<void> = Promise.resolve();
}

export interface ElementSourceEffectResult {
  readonly replacement: boolean;
  readonly unsupported: boolean;
  readonly retiredContextRecoveryCount: number;
}

export async function applyElementSourceEffect(input: Readonly<{
  host: HTMLElement;
  layers: ShadowLayerOwner;
  controller: ElementController;
  desired: ElementDesiredState;
  state: ElementSourceEffectState;
  snapshot: Readonly<ElementDesiredSnapshot>;
}>): Promise<Readonly<ElementSourceEffectResult>> {
  const { snapshot, state } = input;
  const configuration = snapshot.configuration;
  const document = input.host.ownerDocument;
  const window = document.defaultView;
  const create = snapshot.connected && !snapshot.terminal &&
    configuration !== null && configuration.sourceCandidates.length > 0 &&
    input.layers.stylesSupported && window !== null;
  if (snapshot.sourceToken === state.appliedToken && state.appliedCreate === create) {
    await state.operation;
    return Object.freeze({
      replacement: false,
      unsupported: false,
      retiredContextRecoveryCount: 0
    });
  }
  const retiredContextRecoveryCount = activeContextRecoveryCount(input.controller);
  const replacement = create && input.controller.active !== null;
  let unsupported = false;
  if (create) {
    const captured = Object.freeze({
      desired: snapshot,
      configuration: configuration as Readonly<ElementConfiguration>,
      document,
      window: window as Window
    });
    state.captured = captured;
    state.operation = input.controller.replace();
    try { await state.operation; }
    finally { if (state.captured === captured) state.captured = null; }
  } else {
    state.operation = input.controller.retire();
    await state.operation;
    try { input.layers.showBestFallback(); } catch { /* terminal layer */ }
    unsupported = snapshot.connected &&
      (configuration?.sourceCandidates.length ?? 0) > 0 &&
      !input.layers.stylesSupported;
  }
  if (input.desired.snapshot().sourceToken === snapshot.sourceToken) {
    state.appliedToken = snapshot.sourceToken;
    state.appliedCreate = create;
  }
  return Object.freeze({ replacement, unsupported, retiredContextRecoveryCount });
}

export function beginElementSourceInvalidation(input: Readonly<{
  desired: ElementDesiredState;
  controller: ElementController;
  state: ElementSourceEffectState;
}>): Readonly<{
  snapshot: Readonly<ElementDesiredSnapshot>;
  operation: Promise<void>;
  hadActive: boolean;
  retiredContextRecoveryCount: number;
}> {
  const hadActive = input.controller.active !== null;
  const retiredContextRecoveryCount = activeContextRecoveryCount(input.controller);
  const snapshot = input.desired.invalidateSource();
  const operation = input.controller.retire();
  input.state.operation = operation;
  return Object.freeze({
    snapshot,
    operation,
    hadActive,
    retiredContextRecoveryCount
  });
}

function activeContextRecoveryCount(controller: ElementController): number {
  try {
    const value = controller.active?.runtime()?.snapshot().contextRecoveryCount ?? 0;
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
  } catch { return 0; }
}
