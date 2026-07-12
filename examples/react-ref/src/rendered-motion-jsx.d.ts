import type {
  RenderedMotionElement,
  RenderedMotionElementAttributes
} from "@rendered-motion/element";
import type { DetailedHTMLProps, HTMLAttributes } from "react";

type RenderedMotionReactProps = DetailedHTMLProps<
  HTMLAttributes<RenderedMotionElement>,
  RenderedMotionElement
> & RenderedMotionElementAttributes;

declare module "react" {
  namespace JSX {
    interface IntrinsicElements {
      "rendered-motion": RenderedMotionReactProps;
    }
  }
}
