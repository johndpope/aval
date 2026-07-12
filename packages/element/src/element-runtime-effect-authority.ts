import type { ElementAssetGeneration } from "./asset-generation.js";
import {
  elementResumeCurrent,
  elementRuntimeEffectCurrent,
  elementSourceCurrent,
  elementStateCurrent
} from "./element-current-predicates.js";
import type { ElementDesiredState, ElementDesiredSnapshot } from "./element-desired-state.js";
import type {
  ElementResumeCommandKey,
  ElementRuntimeEffectAuthority,
  ElementStateCommandKey
} from "./element-runtime-effects.js";

/** Currentness and failure authority supplied to runtime-effect mechanics. */
export class ElementRuntimeEffectAuthorityView implements ElementRuntimeEffectAuthority {
  readonly #desired: ElementDesiredState;
  readonly #active: () => ElementAssetGeneration | null;
  readonly #failure: (error: unknown, fatal: boolean) => void;
  readonly #presentationUnsupported: () => void;

  public constructor(input: Readonly<{
    desired: ElementDesiredState;
    active: () => ElementAssetGeneration | null;
    failure: (error: unknown, fatal: boolean) => void;
    presentationUnsupported: () => void;
  }>) {
    this.#desired = input.desired;
    this.#active = input.active;
    this.#failure = input.failure;
    this.#presentationUnsupported = input.presentationUnsupported;
  }

  public runtimeEffectCurrent(
    expected: Readonly<ElementDesiredSnapshot>,
    asset: ElementAssetGeneration
  ): boolean {
    return elementRuntimeEffectCurrent({
      desired: this.#desired.snapshot(), expected, active: this.#active(), asset
    });
  }

  public runtimeStateCurrent(
    key: ElementStateCommandKey,
    asset: ElementAssetGeneration
  ): boolean {
    return elementStateCurrent({
      desired: this.#desired.snapshot(), active: this.#active(), asset, key
    });
  }

  public runtimeSourceCurrent(sourceToken: number): boolean {
    return elementSourceCurrent(this.#desired.snapshot(), sourceToken);
  }

  public runtimeResumeCurrent(
    key: ElementResumeCommandKey,
    asset: ElementAssetGeneration
  ): boolean {
    return elementResumeCurrent({
      desired: this.#desired.snapshot(), active: this.#active(), asset, key
    });
  }

  public runtimeEffectFailure(error: unknown, fatal: boolean): void {
    this.#failure(error, fatal);
  }

  public runtimePresentationUnsupported(): void {
    this.#presentationUnsupported();
  }
}
