import { hostInstallationError } from "./element-host-installation-error.js";

export interface DocumentVisibilitySample {
  readonly visible: boolean;
  readonly restored: boolean;
}

type DocumentVisibilitySubscriber = (
  sample: Readonly<DocumentVisibilitySample>
) => void;

const BROKERS = new WeakMap<Document, DocumentVisibilityBroker>();

export function subscribeDocumentVisibility(
  document: Document,
  subscriber: DocumentVisibilitySubscriber
): Readonly<{ current: Readonly<DocumentVisibilitySample>; release(): boolean }> {
  let broker = BROKERS.get(document);
  if (broker === undefined) {
    broker = new DocumentVisibilityBroker(document);
    BROKERS.set(document, broker);
  }
  return broker.subscribe(subscriber);
}

export class DocumentVisibilityBroker {
  readonly #document: Document;
  readonly #window: Window | null;
  readonly #subscribers = new Set<DocumentVisibilitySubscriber>();
  #pageHidden = false;
  #documentListening = false;
  #hideListening = false;
  #showListening = false;

  public constructor(document: Document) {
    this.#document = document;
    this.#window = document.defaultView;
  }

  public subscribe(subscriber: DocumentVisibilitySubscriber): Readonly<{
    current: Readonly<DocumentVisibilitySample>;
    release(): boolean;
  }> {
    this.#subscribers.add(subscriber);
    let current: Readonly<DocumentVisibilitySample>;
    try {
      this.#listen();
      current = this.#sample(false);
    }
    catch (error) {
      this.#subscribers.delete(subscriber);
      throw hostInstallationError(error, () => this.#unlisten());
    }
    let subscriberRemoved = false;
    let released = false;
    return Object.freeze({
      current,
      release: () => {
        if (released) return true;
        if (!subscriberRemoved) {
          subscriberRemoved = true;
          this.#subscribers.delete(subscriber);
        }
        if (this.#subscribers.size > 0) {
          released = true;
          return true;
        }
        released = this.#unlisten();
        return released;
      }
    });
  }

  readonly #visibilityChange = (): void => this.#publish(false);
  readonly #pageHide = (): void => {
    this.#pageHidden = true;
    this.#publish(false);
  };
  readonly #pageShow = (event: PageTransitionEvent): void => {
    this.#pageHidden = false;
    this.#publish(event.persisted === true);
  };

  #sample(restored: boolean): Readonly<DocumentVisibilitySample> {
    return Object.freeze({
      visible: !this.#pageHidden && this.#document.visibilityState !== "hidden",
      restored
    });
  }

  #publish(restored: boolean): void {
    const sample = this.#sample(restored);
    for (const subscriber of [...this.#subscribers]) {
      try { subscriber(sample); } catch { /* subscribers remain independent */ }
    }
  }

  #listen(): void {
    if (!this.#documentListening) {
      this.#documentListening = true;
      this.#document.addEventListener("visibilitychange", this.#visibilityChange);
    }
    if (this.#window !== null && !this.#hideListening) {
      this.#hideListening = true;
      this.#window.addEventListener("pagehide", this.#pageHide);
    }
    if (this.#window !== null && !this.#showListening) {
      this.#showListening = true;
      this.#window.addEventListener("pageshow", this.#pageShow as EventListener);
    }
  }

  #unlisten(): boolean {
    let complete = true;
    if (this.#documentListening) {
      try {
        this.#document.removeEventListener("visibilitychange", this.#visibilityChange);
        this.#documentListening = false;
      } catch { complete = false; }
    }
    if (this.#hideListening) {
      try {
        this.#window?.removeEventListener("pagehide", this.#pageHide);
        this.#hideListening = false;
      } catch { complete = false; }
    }
    if (this.#showListening) {
      try {
        this.#window?.removeEventListener("pageshow", this.#pageShow as EventListener);
        this.#showListening = false;
      } catch { complete = false; }
    }
    return complete &&
      !this.#documentListening && !this.#hideListening && !this.#showListening;
  }
}
