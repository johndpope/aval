export function resolveInteractionTarget(input: Readonly<{
  host: Element;
  override: Element | null;
  id: string;
}>): Element | null {
  const root = input.host.getRootNode();
  if (input.override !== null) {
    assertSameTree(input.host, input.override, root);
    return input.override;
  }
  if (input.id === "") return input.host;
  const candidate = getRootElementById(root, input.id);
  if (candidate === null) return null;
  assertSameTree(input.host, candidate, root);
  return candidate;
}

export function assertInteractionTarget(host: Element, value: unknown): Element | null {
  if (value === null) return null;
  const view = host.ownerDocument.defaultView;
  if (view === null || !(value instanceof view.Element)) {
    throw new TypeError("interactionTarget must be an Element or null");
  }
  assertSameTree(host, value, host.getRootNode());
  return value;
}

function getRootElementById(root: Node, id: string): Element | null {
  if (root.nodeType === Node.DOCUMENT_NODE) {
    return (root as Document).getElementById(id);
  }
  if (root.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
    const fragment = root as ShadowRoot;
    return fragment.getElementById(id);
  }
  return null;
}

function assertSameTree(host: Element, target: Element, root: Node): void {
  if (
    host.ownerDocument !== target.ownerDocument ||
    target.getRootNode() !== root
  ) {
    throw new TypeError("interactionTarget must belong to the same root tree");
  }
}
