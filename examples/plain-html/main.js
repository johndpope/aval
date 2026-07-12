import { defineRenderedMotionElement } from "@rendered-motion/element";

defineRenderedMotionElement();

const motion = document.querySelector("#motion");
const pause = document.querySelector("#pause");
pause.addEventListener("click", () => motion.pause());
