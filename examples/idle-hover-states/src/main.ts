import {
  defineRenderedMotionElement,
  type RenderedMotionElement
} from "@rendered-motion/element";

defineRenderedMotionElement();

const button = document.querySelector<HTMLButtonElement>("#favorite");
const motion = document.querySelector<RenderedMotionElement>("#motion");
if (button === null || motion === null) throw new Error("example markup is incomplete");

button.addEventListener("click", () => {
  const selected = button.getAttribute("aria-pressed") !== "true";
  button.setAttribute("aria-pressed", String(selected));
  void motion.setState(selected ? "selected" : "idle");
});
