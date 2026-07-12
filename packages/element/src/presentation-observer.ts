import type {
  ElementOwnershipHandle,
  ElementOwnershipLedger
} from "./element-ownership-ledger.js";

export interface PresentationBox {
  readonly width: number;
  readonly height: number;
}

export class PresentationObserver {
  readonly #ledger: ElementOwnershipLedger;
  readonly #observer: ResizeObserver;
  readonly #observerOwnership: ElementOwnershipHandle;
  readonly #requestFrame: (callback: FrameRequestCallback) => number;
  readonly #cancelFrame: (handle: number) => void;
  readonly #onBox: (box: Readonly<PresentationBox>) => void;
  #pending: Readonly<PresentationBox> | null = null;
  #frame: number | null = null;
  #frameOwnership: ElementOwnershipHandle | null = null;
  #disposed = false;

  public constructor(options: Readonly<{
    target: Element;
    ledger: ElementOwnershipLedger;
    createObserver(callback: ResizeObserverCallback): ResizeObserver;
    requestFrame(callback: FrameRequestCallback): number;
    cancelFrame(handle: number): void;
    onBox(box: Readonly<PresentationBox>): void;
  }>) {
    this.#ledger = options.ledger;
    this.#requestFrame = options.requestFrame;
    this.#cancelFrame = options.cancelFrame;
    this.#onBox = options.onBox;
    this.#observerOwnership = this.#ledger.acquire("observer");
    try {
      this.#observer = options.createObserver((entries) => {
        for (const entry of entries) {
          if (entry.target !== options.target) continue;
          const box = extractBox(entry);
          if (box !== null) this.#pending = box;
        }
        this.#schedule();
      });
    } catch (error) {
      this.#observerOwnership.complete();
      throw error;
    }
    try { this.#observer.observe(options.target); }
    catch (error) {
      this.#observerOwnership.release(() => this.#observer.disconnect());
      throw error;
    }
  }

  public dispose(): boolean {
    this.#disposed = true;
    let complete = this.#observerOwnership.release(() => this.#observer.disconnect());
    if (this.#frameOwnership !== null) {
      const handle = this.#frame;
      complete = this.#frameOwnership.release(() => {
        if (handle === null) throw new Error("scheduled frame handle is unavailable");
        this.#cancelFrame(handle);
      }) && complete;
    }
    if (complete) {
      this.#frame = null;
      this.#frameOwnership = null;
      this.#pending = null;
    }
    return complete;
  }

  #schedule(): void {
    if (this.#disposed || this.#pending === null || this.#frameOwnership !== null) return;
    const ownership = this.#ledger.acquire("timer");
    let publish = true;
    this.#frameOwnership = ownership;
    try {
      const handle = this.#requestFrame(() => {
        ownership.complete();
        if (this.#frameOwnership === ownership) this.#frameOwnership = null;
        this.#frame = null;
        const pending = this.#pending;
        this.#pending = null;
        if (publish && !this.#disposed && pending !== null) this.#onBox(pending);
      });
      if (ownership.active) this.#frame = handle;
    } catch (error) {
      publish = false;
      if (ownership.active) {
        ownership.release(() => {
          throw new Error("scheduled frame handle is unavailable");
        });
      }
      throw error;
    }
  }
}

function extractBox(entry: ResizeObserverEntry): Readonly<PresentationBox> | null {
  const box = Array.isArray(entry.contentBoxSize)
    ? entry.contentBoxSize[0]
    : entry.contentBoxSize;
  const width = box?.inlineSize ?? entry.contentRect.width;
  const height = box?.blockSize ?? entry.contentRect.height;
  if (!Number.isFinite(width) || !Number.isFinite(height) || width < 0 || height < 0) {
    return null;
  }
  return Object.freeze({ width, height });
}
