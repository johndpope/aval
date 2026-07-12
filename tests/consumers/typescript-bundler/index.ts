import { defineRenderedMotionElement, type RenderedMotionElement } from "@rendered-motion/element";

defineRenderedMotionElement();
const motion = document.querySelector<RenderedMotionElement>("rendered-motion");
if (motion !== null) {
  motion.state = "success";
  void motion.prepare({ timeoutMs: 5_000 });
  motion.addEventListener("visualstatechange", (event) => {
    event.detail.to satisfies string;
    // @ts-expect-error event detail is immutable.
    event.detail.to = "other";
  });
}
