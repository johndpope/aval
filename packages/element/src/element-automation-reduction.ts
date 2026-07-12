import type { ElementDesiredSnapshot, ElementDesiredState } from "./element-desired-state.js";
import type { ElementAutomationSignal } from "./element-host-automation.js";

export interface ElementAutomationReduction {
  readonly snapshot: Readonly<ElementDesiredSnapshot>;
  readonly resizeChanged: boolean;
  readonly motionChanged: boolean;
  readonly restored: boolean;
}

export function reduceElementAutomationSignal(
  desired: ElementDesiredState,
  signal: Exclude<ElementAutomationSignal, Readonly<{ type: "unsupported" }>>
): Readonly<ElementAutomationReduction> {
  let snapshot: Readonly<ElementDesiredSnapshot>;
  switch (signal.type) {
    case "document":
      snapshot = desired.setDocumentVisible(signal.visible, signal.restored);
      break;
    case "intersection":
      snapshot = desired.setIntersection(signal.intersecting);
      break;
    case "observer":
      snapshot = desired.setObserverSupported(signal.supported);
      break;
    case "box":
      snapshot = desired.setBox({ width: signal.width, height: signal.height });
      break;
    case "dpr":
      snapshot = desired.setDpr(signal.value);
      break;
    case "motion":
      snapshot = desired.setHostReduced(signal.value);
  }
  return Object.freeze({
    snapshot,
    resizeChanged: signal.type === "box" || signal.type === "dpr",
    motionChanged: signal.type === "motion",
    restored: signal.type === "document" && signal.restored
  });
}
