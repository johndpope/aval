import { useEffect, useRef } from "react";
import {
  defineRenderedMotionElement,
  type RenderedMotionElement,
  type RenderedMotionErrorDetail,
  type RenderedMotionVisualStateChangeDetail
} from "@rendered-motion/element";

export interface StatusMotionProps {
  readonly state: string;
  readonly src: string;
  readonly onError?: (failure: Readonly<RenderedMotionErrorDetail>) => void;
  readonly onVisualState?: (state: string | null) => void;
}

export function StatusMotion({
  state,
  src,
  onError,
  onVisualState
}: StatusMotionProps) {
  const motion = useRef<RenderedMotionElement>(null);

  useEffect(() => {
    defineRenderedMotionElement();
    const element = motion.current;
    if (element === null) return;

    const handleError = (event: CustomEvent<Readonly<RenderedMotionErrorDetail>>) => {
      onError?.(event.detail);
    };
    const handleVisualState = (
      event: CustomEvent<Readonly<RenderedMotionVisualStateChangeDetail>>
    ) => {
      onVisualState?.(event.detail.to);
    };
    element.addEventListener("error", handleError);
    element.addEventListener("visualstatechange", handleVisualState);
    return () => {
      element.removeEventListener("error", handleError);
      element.removeEventListener("visualstatechange", handleVisualState);
    };
  }, [onError, onVisualState]);

  return (
    <rendered-motion
      ref={motion}
      src={src}
      state={state}
      width={160}
      height={160}
      aria-hidden="true"
    >
      <span slot="fallback" className="motion-fallback" aria-hidden="true">
        {state}
      </span>
    </rendered-motion>
  );
}
