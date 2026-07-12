import type { RenderedMotionElement } from "@rendered-motion/element";
import { createRef } from "react";

const motion = createRef<RenderedMotionElement>();

void (
  <rendered-motion
    ref={motion}
    src="/status.rma"
    state="loading"
    motion="reduce"
    autoplay="manual"
    fit="contain"
    bindings="none"
    width={160}
    height="160"
    aria-label="Decorative status motion"
  />
);

void (
  // @ts-expect-error motion remains a closed public union in JSX
  <rendered-motion motion="sometimes" />
);

void (
  // @ts-expect-error object interaction targets are assigned through a ref
  <rendered-motion interactionTarget={document.body} />
);
