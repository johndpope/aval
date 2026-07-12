/** Owns public DOM event transaction ordering and realm-correct construction. */
export class ElementPublicEvents {
  readonly #host: HTMLElement;
  #depth = 0;

  public constructor(host: HTMLElement) { this.#host = host; }
  public get active(): boolean { return this.#depth > 0; }

  public create<T>(type: string, detail: Readonly<T>): CustomEvent<T> {
    const Constructor = this.#host.ownerDocument.defaultView?.CustomEvent;
    if (Constructor === undefined) throw new Error("CustomEvent is unavailable");
    const localFailure = type === "error";
    return new Constructor(type, {
      detail,
      bubbles: !localFailure,
      composed: !localFailure,
      cancelable: false
    });
  }

  public dispatch(event: Event): boolean {
    this.#depth += 1;
    try { return this.#host.dispatchEvent(event); }
    finally { this.#depth = Math.max(0, this.#depth - 1); }
  }

  public transaction(active: boolean): void {
    this.#depth = Math.max(0, this.#depth + (active ? 1 : -1));
  }

  public after<T>(operation: () => T | PromiseLike<T>): Promise<T> {
    return Promise.resolve().then(() => undefined).then(operation);
  }
}
