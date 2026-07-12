import type { RenderedMotionTraceRecord } from "./public-types.js";
import { nextElementSequence } from "./element-sequence.js";

export const ELEMENT_TRACE_CAPACITY = 512;

export class ElementTrace {
  readonly #records: Readonly<RenderedMotionTraceRecord>[] = [];
  #index = 0;

  public record(kind: string, generation: number): void {
    const safeKind = /^[a-z0-9-]{1,128}$/u.test(kind) ? kind : "unknown";
    const record = Object.freeze({
      index: this.#index = nextElementSequence(this.#index, "trace record"),
      kind: safeKind,
      generation: Number.isSafeInteger(generation) && generation > 0
        ? generation
        : 0
    });
    this.#records.push(record);
    if (this.#records.length > ELEMENT_TRACE_CAPACITY) this.#records.shift();
  }

  public snapshot(): readonly Readonly<RenderedMotionTraceRecord>[] {
    return Object.freeze([...this.#records]);
  }
}
