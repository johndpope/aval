import type { RenderedMotionElement } from "@rendered-motion/element";

export function createM8DiagnosticsPanel(
  element: RenderedMotionElement
): Readonly<{ node: HTMLElement; refresh(trace?: boolean): void; dispose(): void }> {
  const node = document.createElement("pre");
  const refresh = (trace = false): void => {
    node.textContent = JSON.stringify(element.getDiagnostics({ trace }), null, 2);
  };
  refresh();
  return Object.freeze({
    node,
    refresh,
    dispose: () => undefined
  });
}
