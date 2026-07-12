export const RENDERED_MOTION_ATTRIBUTES = Object.freeze([
  "src",
  "integrity",
  "crossorigin",
  "motion",
  "autoplay",
  "fit",
  "bindings",
  "state",
  "interaction-for",
  "width",
  "height"
] as const);

export type RenderedMotionAttribute =
  (typeof RENDERED_MOTION_ATTRIBUTES)[number];

export const RENDERED_MOTION_UPGRADE_PROPERTIES = Object.freeze([
  "src",
  "integrity",
  "crossOrigin",
  "motion",
  "autoplay",
  "fit",
  "bindings",
  "state",
  "interactionFor",
  "interactionTarget",
  "width",
  "height"
] as const);
