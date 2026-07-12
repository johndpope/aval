import type {
  BindingV01,
  RuntimeReadiness,
  RuntimeReadinessResult,
  StaticReason
} from "@rendered-motion/player-web";

import { ElementAttributeReflection } from "./element-attribute-reflection.js";
import {
  RENDERED_MOTION_ATTRIBUTES,
  RENDERED_MOTION_UPGRADE_PROPERTIES
} from "./element-attributes.js";
import { ElementReconciler } from "./element-reconciler.js";
import type {
  RenderedMotionAutoplay,
  RenderedMotionBindings,
  RenderedMotionCrossOrigin,
  RenderedMotionDiagnostics,
  RenderedMotionElement,
  RenderedMotionElementConstructor,
  RenderedMotionFit,
  RenderedMotionMode,
  RenderedMotionMotion
} from "./public-types.js";

/** Browser reflection facade. All coordination and effects live in ElementReconciler. */
export function createRenderedMotionElementClass(
  Base: typeof HTMLElement
): RenderedMotionElementConstructor {
  class RenderedMotionElementImpl extends Base implements RenderedMotionElement {
    public static get observedAttributes(): readonly string[] {
      return RENDERED_MOTION_ATTRIBUTES;
    }

    readonly #attributes: ElementAttributeReflection;
    readonly #reconciler: ElementReconciler;

    public constructor() {
      super();
      this.#attributes = new ElementAttributeReflection(this);
      this.#reconciler = new ElementReconciler(this);
      this.#attributes.upgrade(RENDERED_MOTION_UPGRADE_PROPERTIES);
    }

    public connectedCallback(): void { this.#reconciler.connect(); }
    public disconnectedCallback(): void { this.#reconciler.disconnect(); }
    public adoptedCallback(): void {
      // The next connect observes the concrete root/document and reconciles it.
    }
    public attributeChangedCallback(
      name: string,
      previous: string | null,
      next: string | null
    ): void {
      if (previous !== next) this.#reconciler.configurationChanged(name);
    }

    public get src(): string { return this.#attributes.src; }
    public set src(value: string) { this.#attributes.src = value; }
    public get integrity(): string { return this.#attributes.integrity; }
    public set integrity(value: string) { this.#attributes.integrity = value; }
    public get crossOrigin(): RenderedMotionCrossOrigin { return this.#attributes.crossOrigin; }
    public set crossOrigin(value: RenderedMotionCrossOrigin) { this.#attributes.crossOrigin = value; }
    public get motion(): RenderedMotionMotion { return this.#attributes.motion; }
    public set motion(value: RenderedMotionMotion) { this.#attributes.motion = value; }
    public get autoplay(): RenderedMotionAutoplay { return this.#attributes.autoplay; }
    public set autoplay(value: RenderedMotionAutoplay) { this.#attributes.autoplay = value; }
    public get fit(): RenderedMotionFit | null { return this.#attributes.fit; }
    public set fit(value: RenderedMotionFit | null) { this.#attributes.fit = value; }
    public get bindings(): RenderedMotionBindings { return this.#attributes.bindings; }
    public set bindings(value: RenderedMotionBindings) { this.#attributes.bindings = value; }
    public get state(): string | null { return this.#attributes.state; }
    public set state(value: string | null) { this.#attributes.state = value; }
    public get interactionFor(): string { return this.#attributes.interactionFor; }
    public set interactionFor(value: string) { this.#attributes.interactionFor = value; }
    public get interactionTarget(): Element | null { return this.#reconciler.interactionTarget; }
    public set interactionTarget(value: Element | null) {
      this.#reconciler.setInteractionTarget(value);
    }
    public get width(): number | null { return this.#attributes.width; }
    public set width(value: number | null) { this.#attributes.width = value; }
    public get height(): number | null { return this.#attributes.height; }
    public set height(value: number | null) { this.#attributes.height = value; }

    public get readiness(): RuntimeReadiness { return this.#reconciler.readiness; }
    public get mode(): RenderedMotionMode { return this.#reconciler.mode; }
    public get assurance(): "best-effort" | null { return this.#reconciler.assurance; }
    public get staticReason(): StaticReason | null { return this.#reconciler.staticReason; }
    public get requestedState(): string | null { return this.#reconciler.requestedState; }
    public get visualState(): string | null { return this.#reconciler.visualState; }
    public get isTransitioning(): boolean { return this.#reconciler.transitioning; }
    public get paused(): boolean { return this.#reconciler.paused; }
    public get effectivelyVisible(): boolean { return this.#reconciler.effectivelyVisible; }
    public get stateNames(): readonly string[] { return this.#reconciler.stateNames; }
    public get eventNames(): readonly string[] { return this.#reconciler.eventNames; }
    public get inputBindings(): readonly Readonly<BindingV01>[] {
      return this.#reconciler.inputBindings;
    }

    public prepare(
      options: Readonly<{ signal?: AbortSignal; timeoutMs?: number }> = {}
    ): Promise<RuntimeReadinessResult> {
      return this.#reconciler.prepare(options);
    }
    public setState(name: string): Promise<void> { return this.#reconciler.setState(name); }
    public send(event: string): boolean { return this.#reconciler.send(event); }
    public readyFor(state: string): boolean { return this.#reconciler.readyFor(state); }
    public pause(): void { this.#reconciler.pause(); }
    public resume(): Promise<void> { return this.#reconciler.resume(); }
    public getDiagnostics(
      options: Readonly<{ trace?: boolean }> = {}
    ): Readonly<RenderedMotionDiagnostics> {
      return this.#reconciler.getDiagnostics(options);
    }
    public dispose(): Promise<void> { return this.#reconciler.dispose(); }
  }

  return RenderedMotionElementImpl as unknown as RenderedMotionElementConstructor;
}
