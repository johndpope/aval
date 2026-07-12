export interface EngagementSnapshot {
  readonly pointer: boolean;
  readonly focus: boolean;
  readonly engaged: boolean;
}

export class EngagementController {
  readonly #emit: (source: "engagement.on" | "engagement.off") => void;
  #pointer = false;
  #focus = false;

  public constructor(emit: (source: "engagement.on" | "engagement.off") => void) {
    this.#emit = emit;
  }

  public setPointer(value: boolean): void {
    this.#set(value, this.#focus);
  }

  public setFocus(value: boolean): void {
    this.#set(this.#pointer, value);
  }

  public sample(pointer: boolean, focus: boolean): void {
    this.#pointer = pointer;
    this.#focus = focus;
    this.#emit(pointer || focus ? "engagement.on" : "engagement.off");
  }

  public snapshot(): Readonly<EngagementSnapshot> {
    return Object.freeze({
      pointer: this.#pointer,
      focus: this.#focus,
      engaged: this.#pointer || this.#focus
    });
  }

  #set(pointer: boolean, focus: boolean): void {
    const before = this.#pointer || this.#focus;
    this.#pointer = pointer;
    this.#focus = focus;
    const after = pointer || focus;
    if (after !== before) this.#emit(after ? "engagement.on" : "engagement.off");
  }
}
