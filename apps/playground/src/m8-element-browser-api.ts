export {
  defineRenderedMotionElement,
  RENDERED_MOTION_TAG_NAME
} from "@rendered-motion/element";

export async function importRenderedMotionAuto(): Promise<void> {
  await import("@rendered-motion/element/auto");
}
