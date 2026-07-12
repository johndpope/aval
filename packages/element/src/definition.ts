import {
  isCompatibleRenderedMotionConstructor,
  markRenderedMotionConstructor
} from "./definition-marker.js";
import { RenderedMotionEnvironmentError } from "./errors.js";
import { createRenderedMotionElementClass } from "./rendered-motion-element.js";
import {
  RENDERED_MOTION_TAG_NAME,
  type RenderedMotionElementConstructor
} from "./public-types.js";

export function defineRenderedMotionElement(): RenderedMotionElementConstructor {
  const environment = captureBrowserEnvironment();
  const existing = environment.registry.get(RENDERED_MOTION_TAG_NAME);
  if (existing !== undefined) return requireCompatible(existing);
  const constructor = createRenderedMotionElementClass(environment.HTMLElement);
  markRenderedMotionConstructor(constructor);
  try {
    environment.registry.define(RENDERED_MOTION_TAG_NAME, constructor);
  } catch {
    const raced = environment.registry.get(RENDERED_MOTION_TAG_NAME);
    if (raced !== undefined) return requireCompatible(raced);
    throw new RenderedMotionEnvironmentError(
      "rendered-motion could not be registered"
    );
  }
  return constructor;
}

function requireCompatible(
  constructor: CustomElementConstructor
): RenderedMotionElementConstructor {
  if (!isCompatibleRenderedMotionConstructor(constructor)) {
    throw new RenderedMotionEnvironmentError(
      "rendered-motion is already defined by incompatible code"
    );
  }
  return constructor as RenderedMotionElementConstructor;
}

function captureBrowserEnvironment(): Readonly<{
  registry: CustomElementRegistry;
  HTMLElement: typeof HTMLElement;
}> {
  const scope = globalThis as typeof globalThis & {
    readonly customElements?: CustomElementRegistry;
    readonly HTMLElement?: typeof HTMLElement;
  };
  const registry = scope.customElements;
  const HTMLElementConstructor = scope.HTMLElement;
  if (
    registry === undefined ||
    HTMLElementConstructor === undefined ||
    typeof registry.get !== "function" ||
    typeof registry.define !== "function"
  ) {
    throw new RenderedMotionEnvironmentError();
  }
  return Object.freeze({ registry, HTMLElement: HTMLElementConstructor });
}
