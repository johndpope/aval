import type {
  BindingSource,
  Binding
} from "@pixel-point/aval-player-web";

const BINDING_SOURCES: ReadonlySet<BindingSource> = new Set([
  "activate",
  "engagement.off",
  "engagement.on",
  "focus.in",
  "focus.out",
  "hidden",
  "pointer.enter",
  "pointer.leave",
  "visible"
]);

export class BindingRouter {
  readonly #send: (event: string) => boolean;
  #bindings: ReadonlyMap<BindingSource, string> = new Map();
  #snapshot: readonly Readonly<Binding>[] = Object.freeze([]);
  #enabled = true;

  public constructor(send: (event: string) => boolean) {
    if (typeof send !== "function") throw new TypeError("binding router requires send");
    this.#send = send;
  }

  public install(bindings: readonly Readonly<Binding>[]): void {
    if (!Array.isArray(bindings)) throw new TypeError("bindings must be an array");
    const map = new Map<BindingSource, string>();
    const snapshot: Readonly<Binding>[] = [];
    for (const binding of bindings) {
      if (
        binding === null ||
        typeof binding !== "object" ||
        !BINDING_SOURCES.has(binding.source) ||
        typeof binding.event !== "string"
      ) {
        throw new TypeError("manifest binding is malformed");
      }
      if (map.has(binding.source)) {
        throw new TypeError("manifest binding sources must be unique");
      }
      map.set(binding.source, binding.event);
      snapshot.push(Object.freeze({ source: binding.source, event: binding.event }));
    }
    this.#bindings = map;
    this.#snapshot = Object.freeze(snapshot);
  }

  public setEnabled(enabled: boolean): void {
    this.#enabled = enabled;
  }

  public route(source: BindingSource): boolean {
    if (!this.#enabled) return false;
    const event = this.#bindings.get(source);
    return event === undefined ? false : this.#send(event);
  }

  public snapshot(): readonly Readonly<Binding>[] {
    return this.#snapshot;
  }
}
