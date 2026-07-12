import { RENDERED_MOTION_ELEMENT_API_MAJOR } from "./public-types.js";

export const RENDERED_MOTION_DEFINITION_MARKER = Symbol.for(
  "@rendered-motion/element/definition-api-major"
);

export function markRenderedMotionConstructor(
  constructor: CustomElementConstructor
): void {
  Object.defineProperty(constructor, RENDERED_MOTION_DEFINITION_MARKER, {
    value: RENDERED_MOTION_ELEMENT_API_MAJOR,
    configurable: false,
    enumerable: false,
    writable: false
  });
}

export function isCompatibleRenderedMotionConstructor(
  constructor: CustomElementConstructor
): boolean {
  try {
    return Reflect.get(
      constructor,
      RENDERED_MOTION_DEFINITION_MARKER
    ) === RENDERED_MOTION_ELEMENT_API_MAJOR;
  } catch {
    return false;
  }
}
